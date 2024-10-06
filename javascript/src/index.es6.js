export default class Kestra {
  format(map) {
    return "::" + JSON.stringify(map) + "::";
  }

  #send(map) {
    console.log(this.format(map));
  }

  #metrics(name, type, value, tags) {
    this.#send({
      metrics: [
        {
          name: name,
          type: type,
          value: value,
          tags: tags || {},
        },
      ],
    });
  }

  ouputs(outputs) {
    this.#send({
      outputs: outputs,
    });
  }

  counter(name, value, tags) {
    this.#metrics(name, "counter", value, tags);
  }

  timer(name, duration, tags) {
    if (typeof duration === "function") {
      const start = new Date();
      duration(() => {
        this.#metrics(name, "timer", (new Date() - start) / 1000, tags);
      });
    } else {
      this.#metrics(name, "timer", duration, tags);
    }
  }
}
