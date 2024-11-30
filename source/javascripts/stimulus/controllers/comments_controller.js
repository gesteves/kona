import { Controller } from "@hotwired/stimulus";
import { formatDistanceToNow } from "date-fns";
import Handlebars from "handlebars";

export default class extends Controller {
  static targets = ['commentTemplate', 'introTemplate', 'heading', 'intro', 'spinner', 'container'];
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
    this.renderIntro(this.promptValue, this.urlValue, "join");
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
   * Renders am intro template and replaces the contents of the introTarget with the rendered content.
   * @param {string} prompt - The prompt message to display.
   * @param {string} url - The URL for the "Reply on Bluesky" link.
   * @param {string} verb - The verb to use in the prompt (e.g., "start", "join").
   */
  renderIntro(prompt, url, verb) {
    const template = this.introTemplateTarget.innerHTML;
    const compiledTemplate = Handlebars.compile(template);
    const renderedContent = compiledTemplate({
      prompt: prompt,
      postUrl: url,
      verb: verb,
    });

    this.introTarget.innerHTML = renderedContent;
  }

  /**
   * Renders an error template and replaces the contents of the introTarget with the rendered content.
   * @param {string} error - The error message to display.
   */
  renderError(error) {
    const template = this.introTemplateTarget.innerHTML;
    const compiledTemplate = Handlebars.compile(template);
    const renderedContent = compiledTemplate({ error: error });

    this.introTarget.innerHTML = renderedContent;
  }

  /**
   * Fetches the thread data from the API and updates comments.
   * Handles cases where there are no replies or fetch errors.
   * @async
   */
  async fetchComments() {
    try {
      const thread = await this.getPostThread(
        this.atUriValue,
        this.depthValue,
        this.parentHeightValue,
      );

      if (thread.replies && thread.replies.length > 0) {
        this.updateComments(thread.replies);
      } else {
        this.renderIntro(this.promptValue, this.urlValue, "start");
      }
    } catch (err) {
      console.error("Error fetching comments:", err);
      this.renderError("Oops! Comments failed to load, reload the page to try again.");
    } finally {
      this.spinnerTarget.remove();
    }
  }

  /**
   * Updates the comment section with sorted replies.
   * @param {Array} replies - Array of top-level replies.
   */
  updateComments(replies) {
    // Filter out posts with text that is only the 📌 emoji
    const filteredReplies = replies.filter((reply) => reply.post.record.text.trim() !== "📌");
  
    // Sort the remaining replies
    const sortedReplies = this.sortReplies(filteredReplies, this.sortValue);
  
    sortedReplies.forEach((reply) => {
      this.renderPost(reply);
    });
  }

  /**
   * Sorts replies based on the specified sorting criteria.
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
        return replies.sort((a, b) => 
          (b.post.likeCount ?? 0) - (a.post.likeCount ?? 0)
        );
      case "oldest":
      default:
        return replies.sort((a, b) => 
          new Date(a.post.record.createdAt) - new Date(b.post.record.createdAt)
        );
    }
  }

  /**
   * Renders a single post and its replies recursively.
   * @param {Object} post - The post object to render.
   * @param {Number} depth - The depth of the post in the thread.
   */
  renderPost(post, depth = 0) {
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
      authorProfileLink: `https://bsky.app/profile/${author.handle}`,
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
      replyCount: post.post.replyCount ?? 0,
      repostCount: post.post.repostCount ?? 0,
      likeCount: post.post.likeCount ?? 0,
      postLink: `https://bsky.app/profile/${author.handle}/post/${post.post.uri.split("/").pop()}`,
      seeMoreComments: (!post.replies || post.replies.length === 0) && post.post.replyCount > 0,
      depth: depth,
      isAuthor: author.did === this.authorDidValue,
    };

    // Skip rendering posts with text that is just 📌
    if (post.post.record.text.trim() === "📌") {
      return;
    }

    // Render the compiled template with data
    const rendered = compiledTemplate(data);

    // Convert the rendered HTML string to actual DOM nodes
    const tempContainer = document.createElement("div");
    tempContainer.innerHTML = rendered;

    // Append each child of the temporary container to the actual container
    while (tempContainer.firstChild) {
      this.containerTarget.appendChild(tempContainer.firstChild);
    }

    // Render replies recursively with incremented depth, filtering out 📌 posts
    if (post.replies && post.replies.length > 0) {
      const filteredReplies = post.replies.filter((reply) => reply.post.record.text.trim() !== "📌");
      const sortedReplies = this.sortReplies(filteredReplies, "oldest");
      sortedReplies.forEach((reply) => {
        this.renderPost(reply, depth + 1);
      });
    }
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
    return data.thread;
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
