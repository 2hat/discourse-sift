import { withPluginApi } from 'discourse/lib/plugin-api';

function attachSiftReviewCount(api) {
  api.addFlagProperty('currentUser.sift_review_count');
  api.decorateWidget('hamburger-menu:admin-links', dec => {
    return dec.attach('link', {
      route: 'adminPlugins.sift',
      label: 'sift.title',
      badgeCount: 'sift_review_count',
      badgeClass: 'flagged-posts'
    });
  });
};

function subscribeToReviewCount(messageBus, user) {
  messageBus.subscribe("/sift_counts", function (result) {
    if (result) {
      user.set('sift_review_count', result.sift_review_count || 0);
    }
  });
};

export default {
  name: 'add-sift-count',
  after: 'inject-objects',

  initialize(container) {
    const site = container.lookup("site:main");
    if (!site.get("reviewable_api_enabled")) {
      const user = container.lookup('current-user:main');

      if (user && user.get('staff')) {
        withPluginApi('0.4', attachSiftReviewCount);

        const messageBus = container.lookup('message-bus:main');
        subscribeToReviewCount(messageBus, user);
      }
    }
  }
};
