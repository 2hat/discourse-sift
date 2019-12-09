# frozen_string_literal: true

module DiscourseSift

  RESPONSE_CUSTOM_FIELD ||= "sift".freeze

  def self.should_classify_post?(post)
    return false if post.blank? || (!SiteSetting.sift_enabled?)

    #Don't Classify Private Messages
    return false if post.topic.private_message?

    stripped = post.raw.strip

    # If the entire post is a URI we skip it. This might seem counter intuitive but
    # Discourse already has settings for max links and images for new users. If they
    # pass it means the administrator specifically allowed them.
    uri = URI(stripped) rescue nil
    return false if uri

    # Otherwise check the post!
    true

  end

  def self.with_client
    Sift::Client.with_client do |client|

      yield client
    end
  end

  def self.classify_post(post)
    DiscourseSift.with_client do |client|
      #Rails.logger.error("sift_debug: classify_post Enter: #{post.inspect}")

      result = client.submit_for_classification(post)
      reporter = Discourse.system_user
      passes_policy_guide = result.response
      use_standard_queue = SiteSetting.sift_use_standard_queue

      # Store classification result for every message
      # TODO: potentially this could be configurable?
      store_sift_response(post, result)

      if passes_policy_guide
        # Make post as passed policy guide
        DiscourseSift.move_to_state(post, 'pass_policy_guide')
      elsif result.over_any_max_risk
        # Mark Post As Auto Moderated Queue

        DiscourseSift.move_to_state(post, 'auto_moderated')
        remove_post_and_notify(post, reporter, 'sift_auto_filtered')

        if !use_standard_queue
          reviewable = enqueue_sift_reviewable(post, result, reporter)
          reviewable.perform(reporter, :confirm_failed)
        end

        # Trigger an event that community sift auto moderated a post. This allows moderators to notify chat rooms
        DiscourseEvent.trigger(:sift_auto_moderated)
      else
        #Rails.logger.error("sift_debug: Moderating Post")

        # Use the Discourse Flag Queue?
        # TODO: For now this assumes the user is going to use
        #   the default flag queue settings for visiblilty and
        #   moderation.  Have to do this right now, because the
        #   default behaviour of the Sift custom queue is to delete
        #   the post to hide it, and this screws up the default Flagged queue
        if use_standard_queue

          #Rails.logger.debug("sift_debug: Flagging Post  post: #{post.inspect}")
          #Rails.logger.debug("sift_debug:   active flags: #{post.active_flags.inspect}")

          flag_post_as(post, reporter, result.topic_string)

          # Should we add an extra flags
          SiteSetting.sift_extra_flag_users.split(",").each { |name|
            name = name.strip()
            if !name.blank?
              begin
                # send a flag as this user
                flag_user = User.find_by_username(name)
                if !flag_user.nil?
                  flag_post_as(post, flag_user, result.topic_string)
                else
                  Rails.logger.error("sift_debug: Could not flag post with flag user:#{name}  Could not find user")
                end
              end

            end
          }

        else

          if !SiteSetting.sift_post_stay_visible
            # TODO: Is this setting independent of Custom or Standard reviewable?
            # Should post be hidden/deleted until moderation?
            remove_post_and_notify(post, reporter, 'sift_human_moderation')
          end

          enqueue_sift_reviewable(post, result, reporter)
        end

        if reviewable_api_enabled?
        end

        # Mark Post For Requires Moderation
        DiscourseSift.move_to_state(post, 'requires_moderation')

        # Trigger an event that community sift has an item for human moderators. This allows moderators to notify chat rooms
        DiscourseEvent.trigger(:sift_post_failed_policy_guide)
      end
    end
  end

  def self.stats
    result = PostCustomField.where(name: 'SIFT_STATE').group(:value).count.symbolize_keys!
    result[:auto_moderated] ||= 0
    result[:requires_moderation] ||= 0
    result[:confirmed_failed] ||= 0
    result[:confirmed_passed] ||= 0
    result[:pass_policy_guide] ||= 0
    result[:classified] = result[:auto_moderated] + result[:requires_moderation] + result[:confirmed_failed] + result[:confirmed_passed] + result[:pass_policy_guide]
    result
  end

  def self.requires_moderation
    post_ids = PostCustomField.where(name: 'SIFT_STATE', value: 'requires_moderation').pluck(:post_id)
    Post.with_deleted.where(id: post_ids).includes(:topic, :user).references(:topic)
  end

  def self.move_to_state(post, state, opts = nil)
    opts ||= {}

    return if post.blank? || SiteSetting.sift_use_standard_queue || SiteSetting.sift_api_key.blank?

    post.custom_fields['SIFT_STATE'] = state

    post.save_custom_fields

    msg = { sift_review_count: DiscourseSift.requires_moderation.count }
    MessageBus.publish('/sift_counts', msg, user_ids: User.staff.pluck(:id))

  end

  # These methods are private. Do not call them directly
  def self.reviewable_api_enabled?
    defined?(ReviewableSiftPost)
  end

  def self.flag_post_as(post, user, topic_string)
    # TODO: Can't get newline to render by default.  Might need to investigate overriding template or custom template?
    # message: I18n.t('sift_flag_message') + "</br>\n" + result.topic_string
    message = I18n.t('sift_flag_message') + topic_string

    if reviewable_api_enabled?
      PostActionCreator.create(user, post, :inappropriate, message: message)
    else
      post_action_type = PostActionType.types[:inappropriate]
      PostAction.act(user, post, post_action_type, message: message)
    end
  rescue PostAction::AlreadyActed
    nil # Post already flagged for this user
  rescue Exception => e
    Rails.logger.error("sift_debug: Exception when trying flag as system user: #{e.inspect}")
  end

  def self.remove_post_and_notify(post, reporter, reason)
    # Post Removed Due To Content
    PostDestroyer.new(reporter, post).destroy

    # TODO: Maybe a different message if post sent to mod but still visible?
    # Notify User
    if SiteSetting.sift_notify_user
      Jobs.enqueue(
        :send_system_message,
        user_id: post.user.id,
        message_type: reason,
        message_options: {
          topic_title: post.topic.title
        }
      )
    end
  end

  def self.enqueue_sift_reviewable(post, result, reporter)
    ReviewableSiftPost.needs_review!(
      created_by: reporter, target: post, topic: post.topic,
      reviewable_by_moderator: true,
      payload: { post_cooked: post.cooked, sift: result.raw_response }
    ).tap do |reviewable|

      reviewable.add_score(
        reporter, PostActionType.types[:inappropriate],
        created_at: reviewable.created_at
      )
    end
  end

  def self.store_sift_response(post, result)
    post.custom_fields[DiscourseSift::RESPONSE_CUSTOM_FIELD] = result.raw_response
    post.save_custom_fields(true)
  end

  def self.report_post(post, moderator, reason, extra_reason_remarks)
    #Rails.logger.debug("sift_debug: report_post: reporting using job")

    return if SiteSetting.sift_action_end_point.blank? || SiteSetting.sift_api_key.blank?

    #Rails.logger.debug("sift_debug: report_post: sending to job")
    Jobs.enqueue(:report_post, post_id: post.id, moderator_id: moderator.id, reason: reason, extra_reason_remarks: extra_reason_remarks)
  end
end
