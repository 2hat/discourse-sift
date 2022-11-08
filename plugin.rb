# frozen_string_literal: true

# name: discourse-sift
# about: supports content classifying of posts to Community Sift
# version: 0.2.3
# authors: Richard Kellar, George Thomson
# url: https://github.com/sift/discourse-sift

enabled_site_setting :sift_enabled

# Classes are not loaded at this point so we check for the file
reviewable_api_enabled = File.exist? File.expand_path('../../../app/models/reviewable.rb', __FILE__)

# load dependencies
load File.expand_path('../lib/discourse_sift.rb', __FILE__)
load File.expand_path('../lib/sift.rb', __FILE__)
load File.expand_path('../lib/discourse_sift/engine.rb', __FILE__)

register_asset "stylesheets/sift_classification.scss"

register_asset "stylesheets/mod_queue_styles.scss"
add_admin_route 'sift.title', 'sift'

# And mount the engine
Discourse::Application.routes.append do
  mount ::DiscourseSift::Engine, at: '/admin/plugins/sift'
end

def trigger_post_classification(post)
  return unless DiscourseSift.should_classify_post?(post)

  # Use Job queue
  Jobs.enqueue(:classify_post, post_id: post.id)
end

def trigger_post_report_agree(post_action)
  return unless SiteSetting.sift_reporting_enabled?

  moderator_id = post_action.agreed_by_id
  post_id = post_action.post_id

  # Use Job queue
  DiscourseSift.report_post_action("agree", post_id, moderator_id, nil )
end

after_initialize do

  #
  # TODO: Investigate "before_create_post", "validate_post", PostValidator, PostAnalyzer
  #
  # TODO: [minor] Admin moderation queue does not include topic title, which could be a small issue if the title
  #       of a new topic fails classification but the content is fine.  Minor issue, as moderator has access to the
  #       full topic from a link.

  # Jobs
  require_dependency File.expand_path('../jobs/classify_post.rb', __FILE__)
  require_dependency File.expand_path('../jobs/report_post_action.rb', __FILE__)

  if reviewable_api_enabled
    require_dependency File.expand_path('../models/reviewable_sift_post.rb', __FILE__)
    require_dependency File.expand_path('../serializers/reviewable_sift_post_serializer.rb', __FILE__)
    register_reviewable_type ReviewableSiftPost
  else
    add_to_class(:guardian, :can_view_sift?) do
      user.try(:staff?)
    end

    add_to_serializer(:current_user, :sift_review_count) do
      scope.can_view_sift? ? DiscourseSift.requires_moderation.count : nil
    end

    add_to_serializer(:post, :sift_response) do
      post_custom_fields[DiscourseSift::RESPONSE_CUSTOM_FIELD]
    end
  end

  # Add the flag even if the plugin is disabled.
  add_to_serializer(:site, :reviewable_api_enabled, false) { reviewable_api_enabled }

  class ::ReviewableFlaggedPost
    alias_method :core_build_action, :build_action
  end

  add_to_class(:reviewable_flagged_post, :build_action) do |actions, id, icon:, button_class: nil, bundle: nil, client_action: nil, confirm: false|
    # Rails.logger.debug("sift_debug: in add_to_class: enter")
    # Rails.logger.debug("sift_debug: in add_to_class: id=#{id}")

    action_id = id.to_s

    if !SiteSetting.sift_reporting_enabled?
      # We don't want to override any actions
      action_id = "sift_not_override"
    elsif action_id.start_with?("disagree")
      # We want any disagree mod action
      # Rails.logger.debug("sift_debug: in add_to_class: id == disagree")
      action_id = "disagree"
    end

    case action_id

    when "disagree"
      # Rails.logger.debug("sift_debug: in add_to_class: mapping disagree")
      return core_build_action actions, id, icon: icon, button_class: button_class, bundle: bundle, client_action: 'sift_disagree', confirm: confirm

    else
      # Rails.logger.debug("sift_debug: in add_to_class: mapping else: id=#{id}")
      return core_build_action actions, id, icon: icon, button_class: button_class, bundle: bundle, client_action: client_action, confirm: confirm

    end
  end

  # Store Sift Data
  on(:post_created) do |post, _params|
    begin
      trigger_post_classification(post)
    rescue Exception => e
      Rails.logger.error("sift_debug: Exception in post_create: #{e.inspect}")
      raise e
    end

  end

  on(:post_edited) do |post, _params|
    begin
      #
      # TODO: If a post is edited, it is re-classified in it's entirety.  This could lead
      #       to:
      #         - Post created that fails classification
      #         - Moderator marks post as okay
      #         - user edits post
      #         - Post is reclassified, and the content that failed before will fail again
      #           even if new content would not fail
      #         - Post is marked for moderation again
      #  Not sure if this is a problem, but maybe there is a path forward that can classify
      #  a delta or something?
      #

      #Rails.logger.error("sift_debug: Enter post_edited")
      #Rails.logger.error("sift_debug: custom_fields: #{post.custom_fields.inspect}")
      trigger_post_classification(post)
    rescue Exception => e
      Rails.logger.error("sift_debug: Exception in post_edited: #{e.inspect}")
      raise e
    end
  end

  # Add sift info to user flag payloads

  if reviewable_api_enabled
    on(:reviewable_created) do |reviewable|
      if reviewable.type == "ReviewableFlaggedPost"
        reviewable.payload["sift"] = reviewable.post.custom_fields["sift"]
        reviewable.save!
      end
    end

    add_to_serializer(:reviewable_flagged_post, :sift_response) do
      object.payload[DiscourseSift::RESPONSE_CUSTOM_FIELD]
    end
  end
  register_post_custom_field_type(DiscourseSift::RESPONSE_CUSTOM_FIELD, :json)

  #
  # Add listeners for reporting
  #
  on(:flag_agreed) do |post_action, _params|
    begin
      # Rails.logger.debug("sift_debug: in on(:flag_agreed): action: #{post_action.inspect}, params: #{_params.inspect}")

      trigger_post_report_agree(post_action)
    rescue Exception => e
      Rails.logger.error("sift_debug: Exception in on(:flag_agreed): #{e.inspect}")
      raise e
    end
  end

  if reviewable_api_enabled
    staff_actions = %i[sift_confirmed_failed sift_confirmed_passed sift_ignored]
    extend_list_method(UserHistory, :staff_actions, staff_actions)
  end
end
