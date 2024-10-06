import Kestra from "./index.es6.js";

export default class Logger {
  constructor() {
    this.kestra = new Kestra();
  }

  log(level, message) {
    return {
      logs: (message instanceof Array ? message : [message]).map((value) => {
        switch (level) {
          case "TRACE":
            this.trace(value);
            break;
          case "DEBUG":
            this.debug(value);
            break;
          case "INFO":
            this.info(value);
            break;
          case "WARN":
            this.warn(value);
            break;
          case "ERROR":
            this.error(value);
            break;
          default:
            this.info(value);
            break;
        }
      }),
    };
  }

  trace(...message) {
    console.trace(this.kestra.format({ level: "TRACE", message: message }));
  }

  debug(...message) {
    console.debug(this.kestra.format({ level: "DEBUG", message: message }));
  }

  info(...message) {
    console.info(this.kestra.format({ level: "INFO", message: message }));
  }

  warn(...message) {
    console.warn(this.kestra.format({ level: "WARN", message: message }));
  }

  error(...message) {
    console.error(this.kestra.format({ level: "ERROR", message: message }));
  }
}
