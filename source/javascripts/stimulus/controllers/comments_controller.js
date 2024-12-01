import { Controller } from "@hotwired/stimulus";
import { formatDistanceToNow } from "date-fns";
import { RichText } from '@atproto/api';
import Handlebars from "handlebars";

export default class extends Controller {
  static targets = ['commentTemplate', 'heading', 'intro', 'spinner', 'container'];
  static values = {
    atUri: String,
    url: String,
    authorDid: String,
    depth: Number,
    parentHeight: Number,
    sort: String,
    prompt: String,
  };

  connect() {
    this.observeVisibility();
    this.hiddenReplies = [];
  }

  /**
   * Sets up an IntersectionObserver to fetch comments when the element is visible.
   */
  observeVisibility() {
    this.intersectionObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            this.fetchComments();
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
        this.atUriValue,
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
      this.containerTarget.innerHTML = '<p>Oops! Something went wrong loading the comments, please refresh the page to try again.</p>';
    } finally {
      this.spinnerTarget.remove();
    }
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
      avatar: author.avatar || null,
      displayName: author.displayName || author.handle,
      handle: author.handle,
      authorProfileUrl: `https://bsky.app/profile/${author.handle}`,
      timestamp: new Intl.DateTimeFormat("en-US", {
        weekday: "long",
        year: "numeric",
        month: "long",
        day: "numeric",
        hour: "numeric",
        minute: "numeric",
        hour12: true,
      }).format(createdAt),
      relativeTimestamp: formatDistanceToNow(createdAt, { addSuffix: true }),
      text: post.post.record.text,
      htmlText: this.renderPostTextToHtml(post.post),
      replyCount: post.post.replyCount ?? 0,
      repostCount: post.post.repostCount ?? 0,
      likeCount: post.post.likeCount ?? 0,
      postUrl: `https://bsky.app/profile/${author.handle}/post/${post.post.uri.split("/").pop()}`,
      seeMoreComments: (!post.replies || post.replies.length === 0) && post.post.replyCount > 0 && depth == this.depthValue - 1,
      depth: depth,
      isAuthor: this.isAuthor(author.did),
    };

    // Render the compiled template with data
    const rendered = compiledTemplate(data);

    // Convert the rendered HTML string to actual DOM nodes
    const tempContainer = document.createElement("div");
    tempContainer.innerHTML = rendered;

    // Append each child of the temporary container to the actual container
    while (tempContainer.firstChild) {
      this.containerTarget.appendChild(tempContainer.firstChild);
    }

    // Render replies recursively with incremented depth for indentation
    if (post.replies && post.replies.length > 0) {
      this.processReplies(post.replies, depth + 1, this.sortValue);
    }
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
    return did === this.authorDidValue;
  }

  /**
   * Fetches the thread data from the Bluesky API.
   * @async
   * @param {String} uri - The URI of the thread to fetch.
   * @param {Number} depth - The maximum depth to fetch.
   * @param {Number} parentHeight - The parent height for pagination.
   * @returns {Object} - The fetched thread data.
   * @throws Will throw an error if the API call fails.
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
