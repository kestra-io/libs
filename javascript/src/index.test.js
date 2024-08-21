const Kestra = require("./index.js");

describe('Logger', () => {
    it.each([
        ["TRACE"],
        ["DEBUG"],
        ["INFO"],
        ["WARN"],
        ["ERROR"],
    ])('Simple %s', (type) => {
        const logSpy = jest.spyOn(global.console, type.toLowerCase());

        const val = Math.random();
        Kestra.logger()[type.toLowerCase()](val);

        expect(logSpy).toHaveBeenCalled();
        expect(logSpy).toHaveBeenCalledTimes(1);
        expect(logSpy.mock.calls[0][0].indexOf(type)).toBeGreaterThan(1);
        expect(logSpy.mock.calls[0][0].indexOf(val)).toBeGreaterThan(1);

        logSpy.mockRestore();
    });


    it('Multiple INFO', () => {
        const logSpy = jest.spyOn(global.console, 'info');

        Kestra.logger().info("test1", "test2");

        expect(logSpy).toHaveBeenCalled();
        expect(logSpy).toHaveBeenCalledTimes(1);
        expect(logSpy.mock.calls[0][0].indexOf("INFO")).toBeGreaterThan(1);
        expect(logSpy.mock.calls[0][0].indexOf("test1")).toBeGreaterThan(1);
        expect(logSpy.mock.calls[0][0].indexOf("test2")).toBeGreaterThan(1);

        logSpy.mockRestore();
    });
});

