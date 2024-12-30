function Kestra() {

}

Kestra.format = (map) => {
    return "::" + JSON.stringify(map) + "::";
}


Kestra._send = (map) => {
    console.log(Kestra.format(map));
}

Kestra._metrics = (name, type, value, tags) => {
    Kestra._send({
        "metrics": [
            {
                "name": name,
                "type": type,
                "value": value,
                tags: tags || {}
            }
        ]
    });
}

Kestra.outputs = (outputs) => {
    Kestra._send({
        "outputs": outputs
    });
}

Kestra.counter = (name, value, tags) => {
    Kestra._metrics(name, "counter", value, tags);
}

Kestra.timer = (name, duration, tags) => {
    if (typeof duration === "function") {
        const start = new Date();
        duration(() => {
            Kestra._metrics(name, "timer", (new Date() - start) / 1000, tags);
        });
    } else {
        Kestra._metrics(name, "timer", duration, tags)
    }
}

Kestra.logger = () => {
    return new Logger();
}

class Logger {
    _log(level, message) {
        return {
            "logs": (message instanceof Array ? message : [message])
                .map(value => {
                    return {
                        "level": level,
                        "message": value,
                    }
                })
        };
    };

    trace(...message) {
        console.trace(Kestra.format(this._log("TRACE", message)));
    }

    debug(...message) {
        console.debug(Kestra.format(this._log("DEBUG", message)));
    }

    info(...message) {
        console.info(Kestra.format(this._log("INFO", message)));
    }

    warn(...message) {
        console.warn(Kestra.format(this._log("WARN", message)));
    }

    error(...message) {
        console.error(Kestra.format(this._log("ERROR", message)));
    }
}

module.exports = Kestra;
