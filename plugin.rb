# name: discourse-sift
# about: supports content classifying of posts to Community Sift
# version: 0.2.2
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
  #Rails.logger.debug("sift_debug: Using Job method")
  Jobs.enqueue(:classify_post, post_id: post.id)
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
  require_dependency File.expand_path('../jobs/report_post.rb', __FILE__)


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

  register_post_custom_field_type(DiscourseSift::RESPONSE_CUSTOM_FIELD, :json)
  whitelist_flag_post_custom_field(DiscourseSift::RESPONSE_CUSTOM_FIELD)

  if reviewable_api_enabled
    staff_actions = %i[sift_confirmed_failed sift_confirmed_passed sift_ignored]
    extend_list_method(UserHistory, :staff_actions, staff_actions)
  end
end
