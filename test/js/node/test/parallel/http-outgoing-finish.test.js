//#FILE: test-http-outgoing-finish.js
//#SHA1: cd9dbce2b1b26369349c30bcd94979b354316128
//-----------------
// Copyright Joyent, Inc. and other Node contributors.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so, subject to the
// following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
// NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
// USE OR OTHER DEALINGS IN THE SOFTWARE.

"use strict";

const http = require("http");

test("http outgoing finish", async () => {
  const server = http.createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      write(res);
    });
    server.close();
  });

  await new Promise(resolve => {
    server.listen(0, () => {
      const req = http.request({
        port: server.address().port,
        method: "PUT",
      });
      write(req);
      req.on("response", res => {
        res.resume();
      });
      resolve();
    });
  });
});

const buf = Buffer.alloc(1024 * 16, "x");
function write(out) {
  const name = out.constructor.name;
  let finishEvent = false;
  let endCb = false;

  // First, write until it gets some backpressure
  while (out.write(buf));

  // Now end, and make sure that we don't get the 'finish' event
  // before the tick where the cb gets called.  We give it until
  // nextTick because this is added as a listener before the endcb
  // is registered.  The order is not what we're testing here, just
  // that 'finish' isn't emitted until the stream is fully flushed.
  out.on("finish", () => {
    finishEvent = true;
    console.error(`${name} finish event`);
    process.nextTick(() => {
      expect(endCb).toBe(true);
      console.log(`ok - ${name} finishEvent`);
    });
  });

  out.end(buf, () => {
    endCb = true;
    console.error(`${name} endCb`);
    process.nextTick(() => {
      expect(finishEvent).toBe(true);
      console.log(`ok - ${name} endCb`);
    });
  });
}

//<#END_FILE: test-http-outgoing-finish.js
