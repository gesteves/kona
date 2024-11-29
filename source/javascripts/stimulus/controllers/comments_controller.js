import { Controller } from "@hotwired/stimulus";
import { formatDistanceToNow } from "date-fns";
import Handlebars from "handlebars";

export default class extends Controller {
  static targets = ['commentTemplate', 'spinner', 'prompt', 'firstComment', 'error'];
  static values = {
    atUri: String,
    url: String,
    authorDid: String,
    depth: Number,
    parentHeight: Number,
  };

  connect() {
    this.observeVisibility();
  }

  observeVisibility() {
    this.intersectionObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            this.fetchComments();
            this.intersectionObserver.disconnect();
          }
        });
      },
      { threshold: 0.1 }
    );

    this.intersectionObserver.observe(this.element);
  }

  async fetchComments() {
    try {
      const thread = await this.getPostThread(
        this.atUriValue,
        this.depthValue,
        this.parentHeightValue
      );

      if (thread.replies && thread.replies.length > 0) {
        this.promptTarget.classList.remove("is-hidden");
        this.updateComments(thread.replies);
      } else {
        this.firstCommentTarget.classList.remove("is-hidden");
      }
    } catch (err) {
      console.error("Error fetching comments:", err);
      this.errorTarget.classList.remove("is-hidden");
    } finally {
      this.spinnerTarget.remove();
    }
  }

  updateComments(replies) {
    const container = this.element;

    replies.forEach((reply) => {
      this.renderPost(reply, container);
    });
  }

  renderPost(post, container, depth = 0) {
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
      authorProfileLink: `https://bsky.app/profile/${author.did}`,
      timestamp: new Intl.DateTimeFormat("en-US", {
        weekday: "long",
        year: "numeric",
        month: "long",
        day: "numeric",
        hour: "numeric",
        minute: "numeric",
        hour12: true,
      }).format(createdAt), // Fully formatted timestamp
      relativeTimestamp: formatDistanceToNow(createdAt, { addSuffix: true }), // Relative time
      text: post.post.record.text,
      replyCount: post.post.replyCount ?? 0,
      repostCount: post.post.repostCount ?? 0,
      likeCount: post.post.likeCount ?? 0,
      postLink: `https://bsky.app/profile/${author.did}/post/${post.post.uri.split("/").pop()}`,
      seeMoreComments: (!post.replies || post.replies.length === 0) && post.post.replyCount > 0,
      depth: depth,
      isAuthor: author.did === this.authorDidValue,
    };
  
    // Render the compiled template with data
    const rendered = compiledTemplate(data);
  
    // Convert the rendered HTML string to actual DOM nodes
    const tempContainer = document.createElement("div");
    tempContainer.innerHTML = rendered;

    // Append each child of the temporary container to the actual container
    while (tempContainer.firstChild) {
      container.appendChild(tempContainer.firstChild);
    }
  
    // Render replies recursively with incremented depth
    if (post.replies && post.replies.length > 0) {
      post.replies.forEach((reply) => {
        this.renderPost(reply, container, depth + 1);
      });
    }
  }   

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

  disconnect() {
    if (this.intersectionObserver) {
      this.intersectionObserver.disconnect();
    }
  }
}
