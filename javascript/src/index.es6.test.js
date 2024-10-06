import Logger from "./logger.es6.js";
import {jest} from "@jest/globals";

const logger = new Logger();
describe("Logger", () => {
  it.each([["TRACE"], ["DEBUG"], ["INFO"], ["WARN"], ["ERROR"]])(
    "Simple %s",
    (type) => {
      const logSpy = jest.spyOn(global.console, type.toLowerCase());

      const val = Math.random();
      logger.log(type, (val));

      expect(logSpy).toHaveBeenCalled();
      expect(logSpy).toHaveBeenCalledTimes(1);
      expect(logSpy.mock.calls[0][0].indexOf(type)).toBeGreaterThan(1);
      expect(logSpy.mock.calls[0][0].indexOf(val)).toBeGreaterThan(1);

      logSpy.mockRestore();
    }
  );

  it("Multiple INFO", () => {
    const logSpy = jest.spyOn(global.console, "info");

      logger.info(["test1", "test2"]);

    expect(logSpy).toHaveBeenCalled();
    expect(logSpy).toHaveBeenCalledTimes(1);
    expect(logSpy.mock.calls[0][0].indexOf("INFO")).toBeGreaterThan(1);
    expect(logSpy.mock.calls[0][0].indexOf("test1")).toBeGreaterThan(1);
    expect(logSpy.mock.calls[0][0].indexOf("test2")).toBeGreaterThan(1);

    logSpy.mockRestore();
  });
});
