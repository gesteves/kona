import { Controller } from "@hotwired/stimulus";
import { RichText, AtpAgent } from '@atproto/api';
import { appendToElement } from '../lib/utils';
import Handlebars from "handlebars";

export default class extends Controller {
  static targets = ['commentTemplate', 'heading', 'intro', 'spinner', 'container'];
  static values = {
    url: String,
    depth: { type: Number, default: 6 },
    parentHeight: { type: Number, default: 1000 },
    sort: { type: String, default: "likes" },
    prompt: String,
    authorHandle: String,
  };

  connect() {
    this.hiddenReplies = [];
    this.atUri = this.convertPostUrlToAtUri(this.urlValue);
    if (this.atUri) {
      this.observeVisibility();
    } else {
      // The post for comments isn't valid; so render nothing.
      this.element.remove();
    }
  }

  /**
   * Resolves the DID of the author from the author's handle or the thread's at-uri and stores it.
   * @async
   */
  async resolveAuthorDid() {
    if (this.authorHandleValue) {
      this.authorDid = await this.resolveHandle(this.authorHandleValue);
    } else {
      this.authorDid = await this.extractDidFromAtUri(this.atUri);
    }
  }

  /**
   * Parses a Bluesky post URL and converts it into an at-uri.
   * @param {String} postUrl - The Bluesky post URL.
   * @returns {String|null} - The at-uri if valid, otherwise null.
   */
  convertPostUrlToAtUri(postUrl) {
    if (!postUrl) return null;

    try {
      const url = new URL(postUrl);

      if (url.host !== 'bsky.app' || !url.pathname.startsWith('/profile/')) {
        return null;
      }

      const pathParts = url.pathname.split('/');
      const didOrHandle = pathParts[2];
      const postId = pathParts[4];

      if (!didOrHandle || !postId) {
        return null;
      }

      return `at://${didOrHandle}/app.bsky.feed.post/${postId}`
    } catch (error) {
      console.error("Error parsing post URL:", postUrl, error);
      return null;
    }
  }

  /**
   * Converts an at-uri into a Bluesky post URL, using a handle if provided.
   * @param {String} atUri - The at-uri to convert.
   * @param {String} [handle] - Optional handle to use instead of the DID.
   * @returns {String|null} - The Bluesky post URL if valid, otherwise null.
   */
  convertAtUriToPostUrl(atUri, handle = null) {
    if (!atUri) return null;

    try {
      const parts = atUri.split('/');
      if (parts.length < 5 || parts[0] !== 'at:' || parts[3] !== 'app.bsky.feed.post') {
        return null;
      }

      const didOrHandle = parts[2]; // Extract the DID or handle from the at-uri
      const postId = parts[4]; // Extract the post ID

      if (!didOrHandle || !postId) {
        return null;
      }

      // Use the provided handle if available, otherwise default to the DID or handle from the at-uri
      const profileIdentifier = handle || didOrHandle;

      return `https://bsky.app/profile/${profileIdentifier}/post/${postId}`;
    } catch (error) {
      console.error("Error converting at-uri to post URL:", atUri, error);
      return null;
    }
  }

  /**
   * Extracts the DID from an at-uri.
   * @param {String} atUri - The at-uri to process.
   * @returns {Promise<String|null>} - The extracted DID. Resolves to null if invalid.
   */
  async extractDidFromAtUri(atUri) {
    if (!atUri) return null;

    try {
      const parts = atUri.split('/');
      const didOrHandle = parts[2]; // The third part of the path should contain the DID or handle.
      if (didOrHandle.startsWith('did:plc:')) {
        return didOrHandle; // Return the DID directly if present.
      } else {
        return await this.resolveHandle(didOrHandle); // Otherwise, resolve the handle to a DID.
      }
    } catch (error) {
      console.error("Error extracting DID from at-uri:", atUri, error);
      return null;
    }
  }

  /**
   * Resolves a handle to a DID using the ATP agent.
   * @async
   * @param {String} handle - The handle to resolve. 
   * @returns {Promise<String|null>} - The resolved DID. Resolves to null if the handle is invalid.
   */
  async resolveHandle(handle) {
    const agent = new AtpAgent({ service: 'https://bsky.social' });
    const data = await agent.resolveHandle({ handle: handle });
    return data.data.did;
  }

  /**
   * Sets up an IntersectionObserver to fetch comments when the element is visible.
   */
  observeVisibility() {
    this.intersectionObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            this.resolveAuthorDid()
              .then(() => {
                this.fetchComments();
              })
              .catch((error) => {
                console.error("Failed to resolve author DID:", error);
                this.renderError();
              });
            // Disconnect the observer after the element is visible so we don't fetch comments multiple times.
            this.intersectionObserver.disconnect();
          }
        });
      }
    );

    this.intersectionObserver.observe(this.element);
  }

  /**
   * Fetches the thread data from the API and kicks off processing them.
   * @async
   */
  async fetchComments() {
    try {
      const data = await this.getPostThread(
        this.atUri,
        this.depthValue,
        this.parentHeightValue,
      );

      // Store hidden replies for later.
      this.hiddenReplies = data.threadgate?.record.hiddenReplies || [];

      if (data.thread.replies && data.thread.replies.length > 0) {
        this.processReplies(data.thread.replies, 0, this.sortValue);
      }
    } catch (err) {
      console.error("Error fetching comments:", err);
      this.renderError();
    } finally {
      this.spinnerTarget.remove();
    }
  }

  /**
   * Renders a paragraph with an error message in the container for the comments.
   * @param {String} message - The error message to render.
   */
  renderError(message = "Oops! Something went wrong, please refresh the page to try again.") {
    this.containerTarget.innerHTML = `<p>${message}</p>`;
  }

  /**
   * Processes a list of replies recursively.
   * Handles filtering, sorting, and rendering of replies at any depth.
   * @param {Array} replies - Array of replies to render.
   * @param {Number} depth - The depth of the current replies.
   * @param {String} sortValue - Sorting criteria ("oldest", "newest", "likes").
   */
  processReplies(replies, depth = 0, sortValue = "oldest") {
    // Filter out posts with text that is only the 📌 emoji or are in the hidden replies list
    const filteredReplies = replies.filter(
      (reply) =>
        reply.post.record.text.trim() !== "📌" &&
        !this.hiddenReplies.includes(reply.post.uri)
    );

    // Sort the remaining replies
    const sortedReplies = this.sortReplies(filteredReplies, sortValue);

    // Render each reply and recursively render their replies
    sortedReplies.forEach((reply) => {
      this.renderPost(reply, depth);
    });
  }

  /**
   * Sorts replies based on the specified sorting criteria.
   * When sorted by likes, author's posts appear at the top (chronologically),
   * followed by other posts sorted by likes.
   * @param {Array} replies - Array of replies to sort.
   * @param {String} sortValue - Sorting criteria ("oldest", "newest", "likes").
   * @returns {Array} - Sorted replies array.
   */
  sortReplies(replies, sortValue) {
    switch (sortValue) {
      case "newest":
        return replies.sort((a, b) => 
          new Date(b.post.record.createdAt) - new Date(a.post.record.createdAt)
        );

      case "likes":
        return replies.sort((a, b) => {
          // Separate author's posts
          const aIsAuthor = this.isAuthor(a.post.author.did);
          const bIsAuthor = this.isAuthor(b.post.author.did);

          if (aIsAuthor && bIsAuthor) {
            // Both are author's posts, sort chronologically
            return new Date(a.post.record.createdAt) - new Date(b.post.record.createdAt);
          } else if (aIsAuthor) {
            // Author's post comes first
            return -1;
          } else if (bIsAuthor) {
            // Author's post comes first
            return 1;
          }

          // Sort remaining posts by likes
          return (b.post.likeCount ?? 0) - (a.post.likeCount ?? 0);
        });

      case "oldest":
      default:
        return replies.sort((a, b) => 
          new Date(a.post.record.createdAt) - new Date(b.post.record.createdAt)
        );
    }
  }

  /**
   * Renders a single Bluesky post and its replies recursively.
   * @param {Object} post - The post object to render.
   * @param {Number} depth - The depth of the post in the thread.
   */
  renderPost(post, depth = 0) {
    // Get the Handlebars template from the target element
    const template = this.commentTemplateTarget.innerHTML;

    // Compile the Handlebars template
    const compiledTemplate = Handlebars.compile(template);

    // Prepare the data object for the template
    const author = post.post.author;
    const createdAt = new Date(post.post.record.createdAt);

    const data = {
      authorProfileUrl: `https://bsky.app/profile/${author.handle}`,
      avatar: author.avatar || null,
      depth: depth,
      displayName: author.displayName || author.handle,
      handle: author.handle,
      text: this.renderPostTextToHtml(post.post),
      isAuthor: this.isAuthor(author.did),
      likeCount: post.post.likeCount ?? 0,
      postUrl: this.convertAtUriToPostUrl(post.post.uri, author.handle),
      replyCount: post.post.replyCount ?? 0,
      repostCount: post.post.repostCount ?? 0,
      seeMoreComments: (!post.replies || post.replies.length === 0) && post.post.replyCount > 0 && depth == this.depthValue - 1,
      formattedDate: this.formatDate(createdAt),
      timestamp: createdAt.toISOString(),
    };

    // Render the compiled template with data
    const rendered = compiledTemplate(data);

    appendToElement(rendered, this.containerTarget);

    // Render replies recursively with incremented depth for indentation
    if (post.replies && post.replies.length > 0) {
      this.processReplies(post.replies, depth + 1, this.sortValue);
    }
  }

  /**
   * Formats a date as "Tuesday, December 3, 2024 at 7:44 AM"
   * @param {Date} date - The date to format
   * @returns {String} - The formatted date
   */
  formatDate(date) {
    return new Intl.DateTimeFormat("en-US", {
      weekday: "long",
      year: "numeric",
      month: "long",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      hour12: true,
    }).format(date);
  }

  /**
   * Converts a post's text and facets into an HTML string.
   * @param {Object} post - The post object containing text and facets.
   * @returns {String} - The HTML representation of the post's text.
   */
  renderPostTextToHtml(post) {
    const { text, facets } = post.record;

    // Trust my own posts. Don't trust others' posts.
    const isAuthor = this.isAuthor(post.author.did);
    const rel = isAuthor ? "noopener" : "nofollow noopener ugc";

    // Create a RichText instance with the post's text and facets
    const richText = new RichText({
      text,
      facets,
    });

    // Generate HTML from segments
    let html = '';
    for (const segment of richText.segments()) {
      if (segment.isLink()) {
        html += `<a href="${segment.link?.uri}" rel="${rel}" target="_blank">${segment.text}</a>`;
      } else if (segment.isMention()) {
        html += `<a href="https://bsky.app/profile/${segment.mention?.did}" rel="${rel}" target="_blank">${segment.text}</a>`;
      } else if (segment.isTag()) {
        html += `<a href="https://bsky.app/hashtag/${segment.tag?.tag}" rel="${rel}" target="_blank">${segment.text}</a>`;
      } else {
        html += segment.text;
      }
    }

    return html;
  }

  /**
   * Checks if a DID belongs to the author of the article.
   * @param {String} did - The DID to check.
   * @returns {Boolean} - True if the DID belongs to the author, false otherwise.
  */
  isAuthor(did) {
    return did === this.authorDid;
  }

  /**
   * Fetches the thread data from the Bluesky API.
   * @async
   * @param {String} uri - The URI of the thread to fetch.
   * @param {Number} depth - The maximum depth to fetch.
   * @param {Number} parentHeight - The parent height for pagination.
   * @returns {Object} - The fetched thread data.
   * @throws Will throw an error if the API call fails.
   * @see https://docs.bsky.app/docs/api/app-bsky-feed-get-post-thread
   */
  async getPostThread(uri, depth, parentHeight) {
    const params = new URLSearchParams({ uri });

    // Validate and constrain depth
    if (depth !== null && depth !== undefined) {
      const constrainedDepth = Math.min(parseInt(depth, 10), 1000);
      params.append("depth", constrainedDepth.toString());
    }

    // Validate and constrain parentHeight
    if (parentHeight !== null && parentHeight !== undefined) {
      const constrainedParentHeight = Math.min(parseInt(parentHeight, 10), 1000);
      params.append("parentHeight", constrainedParentHeight.toString());
    }

    // Public endpoint, does not require authentication
    const res = await fetch(
      `https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?${params.toString()}`,
      {
        method: "GET",
        headers: { Accept: "application/json" },
      }
    );

    if (!res.ok) {
      throw new Error("Failed to fetch post thread");
    }

    const data = await res.json();
    return data;
  }

  /**
   * Disconnects the intersection observer when the controller is disconnected.
   */
  disconnect() {
    if (this.intersectionObserver) {
      this.intersectionObserver.disconnect();
    }
  }
}
