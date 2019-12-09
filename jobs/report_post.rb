# frozen_string_literal: true

#
# Based on https://github.com/discourse/discourse-akismet/blob/master/jobs/check_akismet_post.rb
#
module Jobs
  class ReportPost < ::Jobs::Base

    # Send a post to Sift to report agree or disagree with classification
    def execute(args)

      #Rails.logger.debug("sift_debug: report_post job: enter")

      raise Discourse::InvalidParameters.new(:post_action_id) unless args[:post_action_id].present?
      raise Discourse::InvalidParameters.new(:action) unless args[:action].present?
      return unless SiteSetting.sift_enabled?

      action = args[:action]
      post_action_id = args[:post_action_id]

      #Rails.logger.debug("sift_debug: report_post job: post_action_id: #{post_action_id}, action: #{action}")

      post_action = PostAction.where(id: post_action_id).first
      #Rails.logger.debug("sift_debug: report_post job: post_action: #{post_action.inspect}, action: #{action}")

      # Post
      post = post_action.post
      #Rails.logger.debug("sift_debug: report_post job: post: #{post.inspect}")

      return unless post.present?

      # Moderator
      #Rails.logger.debug("sift_debug: report_post job: case agreed: agreed_by_id: #{post_action.agreed_by_id}")
      #Rails.logger.debug("sift_debug: report_post job: case agreed: disagreed_by_id: #{post_action.disagreed_by_id}")

      moderator_id = nil
      case action
      when "agree"
        moderator_id = post_action.agreed_by_id

      when "disagree"
        moderator_id = post_action.disagreed_by_id
      end

      #Rails.logger.debug("sift_debug: report_post job: after case moderator_id: #{moderator_id}")
      moderator = User.where(id: moderator_id).first
      #Rails.logger.debug("sift_debug: report_post job: moderator: #{moderator.inspect}")

      Sift::Client.with_client do |client|
        reason = action
        extra_reason_remarks = args[:extra_reason_remarks]

        client.submit_for_post_action(post, moderator, reason, extra_reason_remarks)
      end

    end
  end
end
