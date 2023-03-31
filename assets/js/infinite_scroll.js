InfiniteScroll = {
  mounted() {
    this.observer = new IntersectionObserver(entries => {
      const entry = entries[0];
      if (entry.isIntersecting) {
        this.pushEvent("load-more");
      }
    });

    this.observer.observe(this.el);
  },
  updated() {
    const pageNumber = this.el.dataset.pageNumber;
  },
  destroyed() {
    this.observer.disconnect();
  },
};

export default InfiniteScroll
