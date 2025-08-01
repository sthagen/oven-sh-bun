//! https://developer.mozilla.org/en-US/docs/Web/API/Body

const Body = @This();

value: Value, // = Value.empty,

pub fn len(this: *Body) Blob.SizeType {
    return this.value.size();
}

pub fn slice(this: *const Body) []const u8 {
    return this.value.slice();
}

pub fn use(this: *Body) Blob {
    return this.value.use();
}

pub fn clone(this: *Body, globalThis: *JSGlobalObject) bun.JSError!Body {
    return Body{
        .value = try this.value.clone(globalThis),
    };
}

pub fn writeFormat(this: *Body, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
    const Writer = @TypeOf(writer);

    try formatter.writeIndent(Writer, writer);
    try writer.writeAll(comptime Output.prettyFmt("<r>bodyUsed<d>:<r> ", enable_ansi_colors));
    try formatter.printAs(.Boolean, Writer, writer, jsc.JSValue.jsBoolean(this.value == .Used), .BooleanObject, enable_ansi_colors);

    if (this.value == .Blob) {
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
        try formatter.writeIndent(Writer, writer);
        try this.value.Blob.writeFormat(Formatter, formatter, writer, enable_ansi_colors);
    } else if (this.value == .InternalBlob or this.value == .WTFStringImpl) {
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
        try formatter.writeIndent(Writer, writer);
        try Blob.writeFormatForSize(false, this.value.size(), writer, enable_ansi_colors);
    } else if (this.value == .Locked) {
        if (this.value.Locked.readable.get(this.value.Locked.global)) |stream| {
            try formatter.printComma(Writer, writer, enable_ansi_colors);
            try writer.writeAll("\n");
            try formatter.writeIndent(Writer, writer);
            try formatter.printAs(.Object, Writer, writer, stream.value, stream.value.jsType(), enable_ansi_colors);
        }
    }
}

pub fn deinit(this: *Body, _: std.mem.Allocator) void {
    this.value.deinit();
}

pub const PendingValue = struct {
    promise: ?JSValue = null,
    readable: jsc.WebCore.ReadableStream.Strong = .{},
    // writable: jsc.WebCore.Sink

    global: *JSGlobalObject,
    task: ?*anyopaque = null,

    /// runs after the data is available.
    onReceiveValue: ?*const fn (ctx: *anyopaque, value: *Value) void = null,

    /// conditionally runs when requesting data
    /// used in HTTP server to ignore request bodies unless asked for it
    onStartBuffering: ?*const fn (ctx: *anyopaque) void = null,
    onStartStreaming: ?*const fn (ctx: *anyopaque) jsc.WebCore.DrainResult = null,
    onReadableStreamAvailable: ?*const fn (ctx: *anyopaque, globalThis: *jsc.JSGlobalObject, readable: jsc.WebCore.ReadableStream) void = null,
    size_hint: Blob.SizeType = 0,

    deinit: bool = false,
    action: Action = Action{ .none = {} },

    /// For Http Client requests
    /// when Content-Length is provided this represents the whole size of the request
    /// If chunked encoded this will represent the total received size (ignoring the chunk headers)
    /// If the size is unknown will be 0
    fn sizeHint(this: *const PendingValue) Blob.SizeType {
        if (this.readable.get(this.global)) |readable| {
            if (readable.ptr == .Bytes) {
                return readable.ptr.Bytes.size_hint;
            }
        }
        return this.size_hint;
    }

    pub fn toAnyBlob(this: *PendingValue) ?AnyBlob {
        if (this.promise != null)
            return null;

        return this.toAnyBlobAllowPromise();
    }

    pub fn isDisturbed(this: *const PendingValue, comptime T: type, globalObject: *jsc.JSGlobalObject, this_value: jsc.JSValue) bool {
        if (this.promise != null) {
            return true;
        }

        if (T.js.bodyGetCached(this_value)) |body_value| {
            if (jsc.WebCore.ReadableStream.isDisturbedValue(body_value, globalObject)) {
                return true;
            }

            return false;
        }

        if (this.readable.get(globalObject)) |readable| {
            return readable.isDisturbed(globalObject);
        }

        return false;
    }

    pub fn isDisturbed2(this: *const PendingValue, globalObject: *jsc.JSGlobalObject) bool {
        if (this.promise != null) {
            return true;
        }

        if (this.readable.get(globalObject)) |readable| {
            return readable.isDisturbed(globalObject);
        }

        return false;
    }
    pub fn isStreamingOrBuffering(this: *PendingValue) bool {
        return this.readable.held.has() or (this.promise != null and !this.promise.?.isEmptyOrUndefinedOrNull());
    }

    pub fn hasPendingPromise(this: *PendingValue) bool {
        const promise = this.promise orelse return false;

        if (promise.asAnyPromise()) |internal| {
            if (internal.status(this.global.vm()) != .pending) {
                promise.unprotect();
                this.promise = null;
                return false;
            }

            return true;
        }

        this.promise = null;
        return false;
    }

    pub fn toAnyBlobAllowPromise(this: *PendingValue) ?AnyBlob {
        var stream = if (this.readable.get(this.global)) |readable| readable else return null;

        if (stream.toAnyBlob(this.global)) |blob| {
            this.readable.deinit();
            return blob;
        }

        return null;
    }

    pub fn setPromise(value: *PendingValue, globalThis: *jsc.JSGlobalObject, action: Action) JSValue {
        value.action = action;
        if (value.readable.get(globalThis)) |readable| {
            switch (action) {
                .getFormData, .getText, .getJSON, .getBlob, .getArrayBuffer, .getBytes => {
                    const promise = switch (action) {
                        .getJSON => globalThis.readableStreamToJSON(readable.value),
                        .getArrayBuffer => globalThis.readableStreamToArrayBuffer(readable.value),
                        .getBytes => globalThis.readableStreamToBytes(readable.value),
                        .getText => globalThis.readableStreamToText(readable.value),
                        .getBlob => globalThis.readableStreamToBlob(readable.value),
                        .getFormData => |form_data| brk: {
                            defer {
                                form_data.?.deinit();
                                value.action.getFormData = null;
                            }

                            break :brk globalThis.readableStreamToFormData(readable.value, switch (form_data.?.encoding) {
                                .Multipart => |multipart| bun.String.init(multipart).toJS(globalThis),
                                .URLEncoded => .js_undefined,
                            });
                        },
                        else => unreachable,
                    };
                    value.readable.deinit();
                    // The ReadableStream within is expected to keep this Promise alive.
                    // If you try to protect() this, it will leak memory because the other end of the ReadableStream won't call it.
                    // See https://github.com/oven-sh/bun/issues/13678
                    return promise;
                },

                .none => {},
            }
        }

        {
            var promise = jsc.JSPromise.create(globalThis);
            const promise_value = promise.toJS();
            value.promise = promise_value;
            promise_value.protect();

            if (value.onStartBuffering) |onStartBuffering| {
                value.onStartBuffering = null;
                onStartBuffering(value.task.?);
            }
            return promise_value;
        }
    }

    pub const Action = union(enum) {
        none: void,
        getText: void,
        getJSON: void,
        getArrayBuffer: void,
        getBytes: void,
        getBlob: void,
        getFormData: ?*bun.FormData.AsyncFormData,
    };
};

/// This is a duplex stream!
pub const Value = union(Tag) {
    const log = Output.scoped(.BodyValue, false);

    const pool_size = if (bun.heap_breakdown.enabled) 0 else 256;
    pub const HiveRef = bun.HiveRef(jsc.WebCore.Body.Value, pool_size);
    pub const HiveAllocator = bun.HiveArray(HiveRef, pool_size).Fallback;

    Blob: Blob,

    /// This is the String type from WebKit
    /// It is reference counted, so we must always deref it (which this does automatically)
    /// Be careful where it can directly be used.
    ///
    /// If it is a latin1 string with only ascii, we can use it directly.
    /// Otherwise, we must convert it to utf8.
    ///
    /// Unless we are sending it directly to JavaScript, for example:
    ///
    ///   var str = "hello world 🤭"
    ///   var response = new Response(str);
    ///   /* Body.Value stays WTFStringImpl */
    ///   var body = await response.text();
    ///
    /// In this case, even though there's an emoji, we can use the StringImpl directly.
    /// BUT, if we were instead using it in the HTTP server, this cannot be used directly.
    ///
    /// When the server calls .toBlobIfPossible(), we will automatically
    /// convert this Value to an InternalBlob
    ///
    /// Example code:
    ///
    ///     Bun.serve({
    ///         fetch(req) {
    ///              /* Body.Value becomes InternalBlob */
    ///              return new Response("hello world 🤭");
    ///         }
    ///     })
    ///
    /// This works for .json(), too.
    WTFStringImpl: bun.WTF.StringImpl,
    /// Single-use Blob
    /// Avoids a heap allocation.
    InternalBlob: InternalBlob,
    /// Single-use Blob that stores the bytes in the Value itself.
    // InlineBlob: InlineBlob,
    Locked: PendingValue,
    Used,
    Empty,
    Error: ValueError,
    Null,

    // We may not have all the data yet
    // So we can't know for sure if it's empty or not
    // We CAN know that it is definitely empty.
    pub fn isDefinitelyEmpty(this: *const Value) bool {
        return switch (this.*) {
            .Null => true,
            .Used, .Empty => true,
            .InternalBlob => this.InternalBlob.slice().len == 0,
            .Blob => this.Blob.size == 0,
            .WTFStringImpl => this.WTFStringImpl.length() == 0,
            .Error, .Locked => false,
        };
    }

    pub const heap_breakdown_label = "BodyValue";
    pub const ValueError = union(enum) {
        AbortReason: jsc.CommonAbortReason,
        SystemError: jsc.SystemError,
        Message: bun.String,
        JSValue: jsc.Strong.Optional,

        pub fn toStreamError(this: *@This(), globalObject: *jsc.JSGlobalObject) streams.Result.StreamError {
            return switch (this.*) {
                .AbortReason => .{
                    .AbortReason = this.AbortReason,
                },
                else => .{
                    .JSValue = this.toJS(globalObject),
                },
            };
        }

        pub fn toJS(this: *@This(), globalObject: *jsc.JSGlobalObject) jsc.JSValue {
            const js_value = switch (this.*) {
                .AbortReason => |reason| reason.toJS(globalObject),
                .SystemError => |system_error| system_error.toErrorInstance(globalObject),
                .Message => |message| message.toErrorInstance(globalObject),
                // do a early return in this case we don't need to create a new Strong
                .JSValue => |js_value| return js_value.get() orelse .js_undefined,
            };
            this.* = .{ .JSValue = .create(js_value, globalObject) };
            return js_value;
        }

        pub fn dupe(this: *const @This(), globalObject: *jsc.JSGlobalObject) @This() {
            var value = this.*;
            switch (this.*) {
                .SystemError => value.SystemError.ref(),
                .Message => value.Message.ref(),
                .JSValue => |js_ref| {
                    if (js_ref.get()) |js_value| {
                        return .{ .JSValue = .create(js_value, globalObject) };
                    }
                    return .{ .JSValue = .empty };
                },
                .AbortReason => {},
            }
            return value;
        }

        pub fn deinit(this: *@This()) void {
            switch (this.*) {
                .SystemError => |system_error| system_error.deref(),
                .Message => |message| message.deref(),
                .JSValue => this.JSValue.deinit(),
                .AbortReason => {},
            }
            // safe empty value after deinit
            this.* = .{ .JSValue = .empty };
        }
    };
    pub fn toBlobIfPossible(this: *Value) void {
        if (this.* == .WTFStringImpl) {
            if (this.WTFStringImpl.toUTF8IfNeeded(bun.default_allocator)) |bytes| {
                var str = this.WTFStringImpl;
                defer str.deref();
                this.* = .{
                    .InternalBlob = InternalBlob{
                        .bytes = std.ArrayList(u8).fromOwnedSlice(bun.default_allocator, @constCast(bytes.slice())),
                        .was_string = true,
                    },
                };
            }
        }

        if (this.* != .Locked)
            return;

        if (this.Locked.toAnyBlob()) |blob| {
            this.* = switch (blob) {
                .Blob => .{ .Blob = blob.Blob },
                .InternalBlob => .{ .InternalBlob = blob.InternalBlob },
                .WTFStringImpl => .{ .WTFStringImpl = blob.WTFStringImpl },
                // .InlineBlob => .{ .InlineBlob = blob.InlineBlob },
            };
        }
    }

    pub fn size(this: *Value) Blob.SizeType {
        return switch (this.*) {
            .Blob => @truncate(this.Blob.getSizeForBindings()),
            .InternalBlob => @as(Blob.SizeType, @truncate(this.InternalBlob.sliceConst().len)),
            .WTFStringImpl => @as(Blob.SizeType, @truncate(this.WTFStringImpl.utf8ByteLength())),
            .Locked => this.Locked.sizeHint(),
            // .InlineBlob => @truncate(Blob.SizeType, this.InlineBlob.sliceConst().len),
            else => 0,
        };
    }

    pub fn fastSize(this: *const Value) Blob.SizeType {
        return switch (this.*) {
            .InternalBlob => @as(Blob.SizeType, @truncate(this.InternalBlob.sliceConst().len)),
            .WTFStringImpl => @as(Blob.SizeType, @truncate(this.WTFStringImpl.byteSlice().len)),
            .Locked => this.Locked.sizeHint(),
            // .InlineBlob => @truncate(Blob.SizeType, this.InlineBlob.sliceConst().len),
            else => 0,
        };
    }

    pub fn memoryCost(this: *const Value) usize {
        return switch (this.*) {
            .InternalBlob => this.InternalBlob.bytes.items.len,
            .WTFStringImpl => this.WTFStringImpl.memoryCost(),
            .Locked => this.Locked.sizeHint(),
            // .InlineBlob => this.InlineBlob.sliceConst().len,
            else => 0,
        };
    }

    pub fn estimatedSize(this: *const Value) usize {
        return switch (this.*) {
            .InternalBlob => this.InternalBlob.sliceConst().len,
            .WTFStringImpl => this.WTFStringImpl.byteSlice().len,
            .Locked => this.Locked.sizeHint(),
            // .InlineBlob => this.InlineBlob.sliceConst().len,
            else => 0,
        };
    }

    pub fn createBlobValue(data: []u8, allocator: std.mem.Allocator, was_string: bool) Value {
        // if (data.len <= InlineBlob.available_bytes) {
        //     var _blob = InlineBlob{
        //         .bytes = undefined,
        //         .was_string = was_string,
        //         .len = @truncate(InlineBlob.IntSize, data.len),
        //     };
        //     @memcpy(&_blob.bytes, data.ptr, data.len);
        //     allocator.free(data);
        //     return Value{
        //         .InlineBlob = _blob,
        //     };
        // }

        return Value{
            .InternalBlob = InternalBlob{
                .bytes = std.ArrayList(u8).fromOwnedSlice(allocator, data),
                .was_string = was_string,
            },
        };
    }

    pub const Tag = enum {
        Blob,
        WTFStringImpl,
        InternalBlob,
        // InlineBlob,
        Locked,
        Used,
        Empty,
        Error,
        Null,
    };

    // pub const empty = Value{ .Empty = {} };

    pub fn toReadableStream(this: *Value, globalThis: *JSGlobalObject) bun.JSError!JSValue {
        jsc.markBinding(@src());

        switch (this.*) {
            .Used => {
                return jsc.WebCore.ReadableStream.used(globalThis);
            },
            .Empty => {
                return jsc.WebCore.ReadableStream.empty(globalThis);
            },
            .Null => {
                return JSValue.null;
            },
            .InternalBlob, .Blob, .WTFStringImpl => {
                var blob = this.use();
                defer blob.detach();
                blob.resolveSize();
                const value = try jsc.WebCore.ReadableStream.fromBlobCopyRef(globalThis, &blob, blob.size);

                this.* = .{
                    .Locked = .{
                        .readable = jsc.WebCore.ReadableStream.Strong.init((try jsc.WebCore.ReadableStream.fromJS(value, globalThis)).?, globalThis),
                        .global = globalThis,
                    },
                };
                return value;
            },
            .Locked => {
                var locked = &this.Locked;
                if (locked.readable.get(globalThis)) |readable| {
                    return readable.value;
                }
                if (locked.promise != null or locked.action != .none) {
                    return jsc.WebCore.ReadableStream.used(globalThis);
                }
                var drain_result: jsc.WebCore.DrainResult = .{
                    .estimated_size = 0,
                };

                if (locked.onStartStreaming) |drain| {
                    locked.onStartStreaming = null;
                    drain_result = drain(locked.task.?);
                }

                if (drain_result == .empty or drain_result == .aborted) {
                    this.* = .{ .Null = {} };
                    return jsc.WebCore.ReadableStream.empty(globalThis);
                }

                var reader = jsc.WebCore.ByteStream.Source.new(.{
                    .context = undefined,
                    .globalThis = globalThis,
                });

                reader.context.setup();

                if (drain_result == .estimated_size) {
                    reader.context.highWaterMark = @as(Blob.SizeType, @truncate(drain_result.estimated_size));
                    reader.context.size_hint = @as(Blob.SizeType, @truncate(drain_result.estimated_size));
                } else if (drain_result == .owned) {
                    reader.context.buffer = drain_result.owned.list;
                    reader.context.size_hint = @as(Blob.SizeType, @truncate(drain_result.owned.size_hint));
                }

                locked.readable = jsc.WebCore.ReadableStream.Strong.init(.{
                    .ptr = .{ .Bytes = &reader.context },
                    .value = try reader.toReadableStream(globalThis),
                }, globalThis);

                if (locked.onReadableStreamAvailable) |onReadableStreamAvailable| {
                    onReadableStreamAvailable(locked.task.?, globalThis, locked.readable.get(globalThis).?);
                }

                return locked.readable.get(globalThis).?.value;
            },
            .Error => {
                // TODO: handle error properly
                return jsc.WebCore.ReadableStream.empty(globalThis);
            },
        }
    }

    pub fn fromJS(globalThis: *JSGlobalObject, value: JSValue) bun.JSError!Value {
        value.ensureStillAlive();

        if (value.isEmptyOrUndefinedOrNull()) {
            return Body.Value{
                .Null = {},
            };
        }

        const js_type = value.jsType();

        if (js_type.isStringLike()) {
            var str = try value.toBunString(globalThis);
            if (str.length() == 0) {
                return Body.Value{
                    .Empty = {},
                };
            }

            assert(str.tag == .WTFStringImpl);

            return Body.Value{
                .WTFStringImpl = str.value.WTFStringImpl,
            };
        }

        if (js_type.isTypedArrayOrArrayBuffer()) {
            if (value.asArrayBuffer(globalThis)) |buffer| {
                const bytes = buffer.byteSlice();

                if (bytes.len == 0) {
                    return Body.Value{
                        .Empty = {},
                    };
                }

                return Body.Value{
                    .InternalBlob = .{
                        .bytes = std.ArrayList(u8){
                            .items = bun.default_allocator.dupe(u8, bytes) catch {
                                return globalThis.throwValue(ZigString.static("Failed to clone ArrayBufferView").toErrorInstance(globalThis));
                            },
                            .capacity = bytes.len,
                            .allocator = bun.default_allocator,
                        },
                        .was_string = false,
                    },
                };
            }
        }

        if (value.as(jsc.DOMFormData)) |form_data| {
            return Body.Value{
                .Blob = Blob.fromDOMFormData(globalThis, bun.default_allocator, form_data),
            };
        }

        if (value.as(jsc.URLSearchParams)) |search_params| {
            return Body.Value{
                .Blob = Blob.fromURLSearchParams(globalThis, bun.default_allocator, search_params),
            };
        }

        if (js_type == .DOMWrapper) {
            if (value.as(Blob)) |blob| {
                return Body.Value{
                    // We must preserve "type" so that DOMFormData and the "type" field are preserved.
                    .Blob = blob.dupeWithContentType(true),
                };
            }
        }

        value.ensureStillAlive();

        if (try jsc.WebCore.ReadableStream.fromJS(value, globalThis)) |readable| {
            if (readable.isDisturbed(globalThis)) {
                return globalThis.throw("ReadableStream has already been used", .{});
            }

            switch (readable.ptr) {
                .Blob => |blob| {
                    defer readable.forceDetach(globalThis);
                    if (blob.toAnyBlob(globalThis)) |any_blob| {
                        return switch (any_blob) {
                            .Blob => .{ .Blob = any_blob.Blob },
                            .InternalBlob => .{ .InternalBlob = any_blob.InternalBlob },
                            .WTFStringImpl => .{ .WTFStringImpl = any_blob.WTFStringImpl },
                        };
                    }

                    return .Empty;
                },
                else => {},
            }

            return Body.Value.fromReadableStreamWithoutLockCheck(readable, globalThis);
        }

        return Body.Value{
            .Blob = Blob.get(globalThis, value, true, false) catch |err| {
                if (!globalThis.hasException()) {
                    if (err == error.InvalidArguments) {
                        return globalThis.throwInvalidArguments("Expected an Array", .{});
                    }

                    return globalThis.throwInvalidArguments("Invalid Body object", .{});
                }

                return error.JSError;
            },
        };
    }

    pub fn fromReadableStreamWithoutLockCheck(readable: jsc.WebCore.ReadableStream, globalThis: *JSGlobalObject) Value {
        return .{
            .Locked = .{
                .readable = jsc.WebCore.ReadableStream.Strong.init(readable, globalThis),
                .global = globalThis,
            },
        };
    }

    pub fn resolve(
        to_resolve: *Value,
        new: *Value,
        global: *JSGlobalObject,
        headers: ?*FetchHeaders,
    ) void {
        log("resolve", .{});
        if (to_resolve.* == .Locked) {
            var locked = &to_resolve.Locked;

            if (locked.readable.get(global)) |readable| {
                readable.done(global);
                locked.readable.deinit();
            }

            if (locked.onReceiveValue) |callback| {
                locked.onReceiveValue = null;
                callback(locked.task.?, new);
                return;
            }

            if (locked.promise) |promise_| {
                const promise = promise_.asAnyPromise().?;
                locked.promise = null;

                switch (locked.action) {
                    // These ones must use promise.wrap() to handle exceptions thrown while calling .toJS() on the value.
                    // These exceptions can happen if the String is too long, ArrayBuffer is too large, JSON parse error, etc.
                    .getText => {
                        switch (new.*) {
                            .WTFStringImpl,
                            .InternalBlob,
                            // .InlineBlob,
                            => {
                                var blob = new.useAsAnyBlobAllowNonUTF8String();
                                promise.wrap(global, AnyBlob.toStringTransfer, .{ &blob, global });
                            },
                            else => {
                                var blob = new.use();
                                promise.wrap(global, Blob.toStringTransfer, .{ &blob, global });
                            },
                        }
                    },
                    .getJSON => {
                        var blob = new.useAsAnyBlobAllowNonUTF8String();
                        promise.wrap(global, AnyBlob.toJSONShare, .{ &blob, global });
                        blob.detach();
                    },
                    .getArrayBuffer => {
                        var blob = new.useAsAnyBlobAllowNonUTF8String();
                        promise.wrap(global, AnyBlob.toArrayBufferTransfer, .{ &blob, global });
                    },
                    .getBytes => {
                        var blob = new.useAsAnyBlobAllowNonUTF8String();
                        promise.wrap(global, AnyBlob.toUint8ArrayTransfer, .{ &blob, global });
                    },

                    .getFormData => inner: {
                        var blob = new.useAsAnyBlob();
                        defer blob.detach();
                        var async_form_data: *bun.FormData.AsyncFormData = locked.action.getFormData orelse {
                            promise.reject(global, ZigString.init("Internal error: task for FormData must not be null").toErrorInstance(global));
                            break :inner;
                        };
                        defer async_form_data.deinit();
                        async_form_data.toJS(global, blob.slice(), promise);
                    },
                    .none, .getBlob => {
                        var blob = Blob.new(new.use());
                        blob.allocator = bun.default_allocator;
                        if (headers) |fetch_headers| {
                            if (fetch_headers.fastGet(.ContentType)) |content_type| {
                                var content_slice = content_type.toSlice(bun.default_allocator);
                                defer content_slice.deinit();
                                var allocated = false;
                                const mimeType = MimeType.init(content_slice.slice(), bun.default_allocator, &allocated);
                                blob.content_type = mimeType.value;
                                blob.content_type_allocated = allocated;
                                blob.content_type_was_set = true;
                                if (blob.store != null) {
                                    blob.store.?.mime_type = mimeType;
                                }
                            }
                        }
                        if (!blob.content_type_was_set and blob.store != null) {
                            blob.content_type = MimeType.text.value;
                            blob.content_type_allocated = false;
                            blob.content_type_was_set = true;
                            blob.store.?.mime_type = MimeType.text;
                        }
                        promise.resolve(global, blob.toJS(global));
                    },
                }
                promise_.unprotect();
            }
        }
    }
    pub fn slice(this: *const Value) []const u8 {
        return switch (this.*) {
            .Blob => this.Blob.sharedView(),
            .InternalBlob => this.InternalBlob.sliceConst(),
            .WTFStringImpl => if (this.WTFStringImpl.canUseAsUTF8()) this.WTFStringImpl.latin1Slice() else "",
            // .InlineBlob => this.InlineBlob.sliceConst(),
            else => "",
        };
    }

    pub fn use(this: *Value) Blob {
        this.toBlobIfPossible();

        switch (this.*) {
            .Blob => {
                const new_blob = this.Blob;
                assert(new_blob.allocator == null); // owned by Body
                this.* = .{ .Used = {} };
                return new_blob;
            },
            .InternalBlob => {
                const new_blob = Blob.init(
                    this.InternalBlob.toOwnedSlice(),
                    // we will never resize it from here
                    // we have to use the default allocator
                    // even if it was actually allocated on a different thread
                    bun.default_allocator,
                    jsc.VirtualMachine.get().global,
                );

                this.* = .{ .Used = {} };
                return new_blob;
            },
            .WTFStringImpl => {
                var new_blob: Blob = undefined;
                var wtf = this.WTFStringImpl;
                defer wtf.deref();
                if (wtf.toUTF8IfNeeded(bun.default_allocator)) |allocated_slice| {
                    new_blob = Blob.init(
                        @constCast(allocated_slice.slice()),
                        bun.default_allocator,
                        jsc.VirtualMachine.get().global,
                    );
                } else {
                    new_blob = Blob.init(
                        bun.default_allocator.dupe(u8, wtf.latin1Slice()) catch bun.outOfMemory(),
                        bun.default_allocator,
                        jsc.VirtualMachine.get().global,
                    );
                }

                this.* = .{ .Used = {} };
                return new_blob;
            },
            // .InlineBlob => {
            //     const cloned = this.InlineBlob.bytes;
            //     // keep same behavior as InternalBlob but clone the data
            //     const new_blob = Blob.create(
            //         cloned[0..this.InlineBlob.len],
            //         bun.default_allocator,
            //         jsc.VirtualMachine.get().global,
            //         false,
            //     );

            //     this.* = .{ .Used = {} };
            //     return new_blob;
            // },
            else => {
                return Blob.initEmpty(undefined);
            },
        }
    }

    pub fn tryUseAsAnyBlob(this: *Value) ?AnyBlob {
        if (this.* == .WTFStringImpl) {
            if (this.WTFStringImpl.canUseAsUTF8()) {
                return AnyBlob{ .WTFStringImpl = this.WTFStringImpl };
            }
        }

        const any_blob: AnyBlob = switch (this.*) {
            .Blob => AnyBlob{ .Blob = this.Blob },
            .InternalBlob => AnyBlob{ .InternalBlob = this.InternalBlob },
            // .InlineBlob => AnyBlob{ .InlineBlob = this.InlineBlob },
            .Locked => this.Locked.toAnyBlobAllowPromise() orelse return null,
            else => return null,
        };

        this.* = .{ .Used = {} };
        return any_blob;
    }

    pub fn useAsAnyBlob(this: *Value) AnyBlob {
        const any_blob: AnyBlob = switch (this.*) {
            .Blob => .{ .Blob = this.Blob },
            .InternalBlob => .{ .InternalBlob = this.InternalBlob },
            .WTFStringImpl => |str| brk: {
                if (str.toUTF8IfNeeded(bun.default_allocator)) |utf8| {
                    defer str.deref();
                    break :brk .{
                        .InternalBlob = InternalBlob{
                            .bytes = std.ArrayList(u8).fromOwnedSlice(bun.default_allocator, @constCast(utf8.slice())),
                            .was_string = true,
                        },
                    };
                } else {
                    break :brk .{
                        .WTFStringImpl = str,
                    };
                }
            },
            // .InlineBlob => .{ .InlineBlob = this.InlineBlob },
            .Locked => this.Locked.toAnyBlobAllowPromise() orelse AnyBlob{ .Blob = .{} },
            else => .{ .Blob = Blob.initEmpty(undefined) },
        };

        this.* = if (this.* == .Null)
            .{ .Null = {} }
        else
            .{ .Used = {} };
        return any_blob;
    }

    pub fn useAsAnyBlobAllowNonUTF8String(this: *Value) AnyBlob {
        const any_blob: AnyBlob = switch (this.*) {
            .Blob => .{ .Blob = this.Blob },
            .InternalBlob => .{ .InternalBlob = this.InternalBlob },
            .WTFStringImpl => .{ .WTFStringImpl = this.WTFStringImpl },
            // .InlineBlob => .{ .InlineBlob = this.InlineBlob },
            .Locked => this.Locked.toAnyBlobAllowPromise() orelse AnyBlob{ .Blob = .{} },
            else => .{ .Blob = Blob.initEmpty(undefined) },
        };

        this.* = if (this.* == .Null)
            .{ .Null = {} }
        else
            .{ .Used = {} };
        return any_blob;
    }

    pub fn toErrorInstance(this: *Value, err: ValueError, global: *JSGlobalObject) void {
        if (this.* == .Locked) {
            var locked = this.Locked;
            this.* = .{ .Error = err };

            var strong_readable = locked.readable;
            locked.readable = .{};
            defer strong_readable.deinit();

            if (locked.hasPendingPromise()) {
                const promise = locked.promise.?;
                defer promise.unprotect();
                locked.promise = null;

                if (promise.asAnyPromise()) |internal| {
                    internal.reject(global, this.Error.toJS(global));
                }
            }

            // The Promise version goes before the ReadableStream version incase the Promise version is used too.
            // Avoid creating unnecessary duplicate JSValue.
            if (strong_readable.get(global)) |readable| {
                if (readable.ptr == .Bytes) {
                    readable.ptr.Bytes.onData(
                        .{ .err = this.Error.toStreamError(global) },
                        bun.default_allocator,
                    );
                } else {
                    readable.abort(global);
                }
            }

            if (locked.onReceiveValue) |onReceiveValue| {
                locked.onReceiveValue = null;
                onReceiveValue(locked.task.?, this);
            }
            return;
        }
        this.* = .{ .Error = err };
    }

    pub fn toError(this: *Value, err: anyerror, global: *JSGlobalObject) void {
        return this.toErrorInstance(.{ .Message = bun.String.createFormat(
            "Error reading file {s}",
            .{@errorName(err)},
        ) catch bun.outOfMemory() }, global);
    }

    pub fn deinit(this: *Value) void {
        const tag = @as(Tag, this.*);
        if (tag == .Locked) {
            if (!this.Locked.deinit) {
                this.Locked.deinit = true;
                this.Locked.readable.deinit();
                this.Locked.readable = .{};
            }

            return;
        }

        if (tag == .InternalBlob) {
            this.InternalBlob.clearAndFree();
            this.* = Value{ .Null = {} };
        }

        if (tag == .Blob) {
            this.Blob.deinit();
            this.* = Value{ .Null = {} };
        }

        if (tag == .WTFStringImpl) {
            this.WTFStringImpl.deref();
            this.* = Value{ .Null = {} };
        }

        if (tag == .Error) {
            this.Error.deinit();
        }
    }

    pub fn tee(this: *Value, globalThis: *jsc.JSGlobalObject) bun.JSError!Value {
        var locked = &this.Locked;

        if (locked.readable.isDisturbed(globalThis)) {
            return Value{ .Used = {} };
        }

        if (try locked.readable.tee(globalThis)) |readable| {
            return Value{
                .Locked = .{
                    .readable = jsc.WebCore.ReadableStream.Strong.init(readable, globalThis),
                    .global = globalThis,
                },
            };
        }
        if (locked.promise != null or locked.action != .none or locked.readable.has()) {
            return Value{ .Used = {} };
        }

        var drain_result: jsc.WebCore.DrainResult = .{
            .estimated_size = 0,
        };

        if (locked.onStartStreaming) |drain| {
            locked.onStartStreaming = null;
            drain_result = drain(locked.task.?);
        }

        if (drain_result == .empty or drain_result == .aborted) {
            this.* = .{ .Null = {} };
            return Value{ .Null = {} };
        }

        var reader = jsc.WebCore.ByteStream.Source.new(.{
            .context = undefined,
            .globalThis = globalThis,
        });

        reader.context.setup();

        if (drain_result == .estimated_size) {
            reader.context.highWaterMark = @as(Blob.SizeType, @truncate(drain_result.estimated_size));
            reader.context.size_hint = @as(Blob.SizeType, @truncate(drain_result.estimated_size));
        } else if (drain_result == .owned) {
            reader.context.buffer = drain_result.owned.list;
            reader.context.size_hint = @as(Blob.SizeType, @truncate(drain_result.owned.size_hint));
        }

        locked.readable = jsc.WebCore.ReadableStream.Strong.init(.{
            .ptr = .{ .Bytes = &reader.context },
            .value = try reader.toReadableStream(globalThis),
        }, globalThis);

        if (locked.onReadableStreamAvailable) |onReadableStreamAvailable| {
            onReadableStreamAvailable(locked.task.?, globalThis, locked.readable.get(globalThis).?);
        }

        const teed = (try locked.readable.tee(globalThis)) orelse return Value{ .Used = {} };

        return Value{
            .Locked = .{
                .readable = jsc.WebCore.ReadableStream.Strong.init(teed, globalThis),
                .global = globalThis,
            },
        };
    }

    pub fn clone(this: *Value, globalThis: *jsc.JSGlobalObject) bun.JSError!Value {
        this.toBlobIfPossible();

        if (this.* == .Locked) {
            return this.tee(globalThis);
        }

        if (this.* == .InternalBlob) {
            var internal_blob = this.InternalBlob;
            this.* = .{
                .Blob = Blob.init(
                    internal_blob.toOwnedSlice(),
                    internal_blob.bytes.allocator,
                    globalThis,
                ),
            };
        }

        // if (this.* == .InlineBlob) {
        //     return this.*;
        // }

        if (this.* == .Blob) {
            return Value{ .Blob = this.Blob.dupe() };
        }

        if (this.* == .WTFStringImpl) {
            this.WTFStringImpl.ref();
            return Value{ .WTFStringImpl = this.WTFStringImpl };
        }

        if (this.* == .Null) {
            return Value{ .Null = {} };
        }

        return Value{ .Empty = {} };
    }
};

// https://github.com/WebKit/webkit/blob/main/Source/WebCore/Modules/fetch/FetchBody.cpp#L45
pub fn extract(
    globalThis: *JSGlobalObject,
    value: JSValue,
) bun.JSError!Body {
    var body = Body{ .value = Value{ .Null = {} } };

    body.value = try Value.fromJS(globalThis, value);
    if (body.value == .Blob) {
        assert(body.value.Blob.allocator == null); // owned by Body
    }
    return body;
}

pub fn Mixin(comptime Type: type) type {
    return struct {
        pub fn getText(this: *Type, globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
            var value: *Body.Value = this.getBodyValue();
            if (value.* == .Used) {
                return handleBodyAlreadyUsed(globalObject);
            }

            if (value.* == .Locked) {
                if (value.Locked.action != .none or value.Locked.isDisturbed(Type, globalObject, callframe.this())) {
                    return handleBodyAlreadyUsed(globalObject);
                }

                return value.Locked.setPromise(globalObject, .{ .getText = {} });
            }

            var blob = value.useAsAnyBlobAllowNonUTF8String();
            return jsc.JSPromise.wrap(globalObject, lifetimeWrap(AnyBlob.toString, .transfer), .{ &blob, globalObject });
        }

        pub fn getBody(this: *Type, globalThis: *jsc.JSGlobalObject) bun.JSError!JSValue {
            var body: *Body.Value = this.getBodyValue();

            if (body.* == .Used) {
                return jsc.WebCore.ReadableStream.used(globalThis);
            }

            return body.toReadableStream(globalThis);
        }

        pub fn getBodyUsed(this: *Type, globalObject: *jsc.JSGlobalObject) JSValue {
            return JSValue.jsBoolean(
                switch (this.getBodyValue().*) {
                    .Used => true,
                    .Locked => |*pending| brk: {
                        if (pending.action != .none) {
                            break :brk true;
                        }

                        if (pending.readable.get(globalObject)) |*stream| {
                            break :brk stream.isDisturbed(globalObject);
                        }

                        break :brk false;
                    },
                    else => false,
                },
            );
        }

        fn lifetimeWrap(comptime Fn: anytype, comptime lifetime: jsc.WebCore.Lifetime) fn (*AnyBlob, *jsc.JSGlobalObject) jsc.JSValue {
            return struct {
                fn wrap(this: *AnyBlob, globalObject: *jsc.JSGlobalObject) jsc.JSValue {
                    return jsc.toJSHostCall(globalObject, @src(), Fn, .{ this, globalObject, lifetime });
                }
            }.wrap;
        }

        pub fn getJSON(this: *Type, globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
            var value: *Body.Value = this.getBodyValue();
            if (value.* == .Used) {
                return handleBodyAlreadyUsed(globalObject);
            }

            if (value.* == .Locked) {
                if (value.Locked.action != .none or value.Locked.isDisturbed(Type, globalObject, callframe.this())) {
                    return handleBodyAlreadyUsed(globalObject);
                }

                value.toBlobIfPossible();
                if (value.* == .Locked) {
                    return value.Locked.setPromise(globalObject, .{ .getJSON = {} });
                }
            }

            var blob = value.useAsAnyBlobAllowNonUTF8String();

            return jsc.JSPromise.wrap(globalObject, lifetimeWrap(AnyBlob.toJSON, .share), .{ &blob, globalObject });
        }

        fn handleBodyAlreadyUsed(globalObject: *jsc.JSGlobalObject) JSValue {
            return globalObject.ERR(.BODY_ALREADY_USED, "Body already used", .{}).reject();
        }

        pub fn getArrayBuffer(this: *Type, globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
            var value: *Body.Value = this.getBodyValue();

            if (value.* == .Used) {
                return handleBodyAlreadyUsed(globalObject);
            }

            if (value.* == .Locked) {
                if (value.Locked.action != .none or value.Locked.isDisturbed(Type, globalObject, callframe.this())) {
                    return handleBodyAlreadyUsed(globalObject);
                }
                value.toBlobIfPossible();

                if (value.* == .Locked) {
                    return value.Locked.setPromise(globalObject, .{ .getArrayBuffer = {} });
                }
            }

            // toArrayBuffer in AnyBlob checks for non-UTF8 strings
            var blob: AnyBlob = value.useAsAnyBlobAllowNonUTF8String();

            return jsc.JSPromise.wrap(globalObject, lifetimeWrap(AnyBlob.toArrayBuffer, .transfer), .{ &blob, globalObject });
        }

        pub fn getBytes(this: *Type, globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
            var value: *Body.Value = this.getBodyValue();

            if (value.* == .Used) {
                return handleBodyAlreadyUsed(globalObject);
            }

            if (value.* == .Locked) {
                if (value.Locked.action != .none or value.Locked.isDisturbed(Type, globalObject, callframe.this())) {
                    return handleBodyAlreadyUsed(globalObject);
                }
                value.toBlobIfPossible();
                if (value.* == .Locked) {
                    return value.Locked.setPromise(globalObject, .{ .getBytes = {} });
                }
            }

            // toArrayBuffer in AnyBlob checks for non-UTF8 strings
            var blob: AnyBlob = value.useAsAnyBlobAllowNonUTF8String();
            return jsc.JSPromise.wrap(globalObject, lifetimeWrap(AnyBlob.toUint8Array, .transfer), .{ &blob, globalObject });
        }

        pub fn getFormData(this: *Type, globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
            var value: *Body.Value = this.getBodyValue();

            if (value.* == .Used) {
                return handleBodyAlreadyUsed(globalObject);
            }

            if (value.* == .Locked) {
                if (value.Locked.action != .none or value.Locked.isDisturbed(Type, globalObject, callframe.this())) {
                    return handleBodyAlreadyUsed(globalObject);
                }
                value.toBlobIfPossible();
            }

            var encoder = (try this.getFormDataEncoding()) orelse {
                // TODO: catch specific errors from getFormDataEncoding
                return globalObject.ERR(.FORMDATA_PARSE_ERROR, "Can't decode form data from body because of incorrect MIME type/boundary", .{}).reject();
            };

            if (value.* == .Locked) {
                return value.Locked.setPromise(globalObject, .{ .getFormData = encoder });
            }

            var blob: AnyBlob = value.useAsAnyBlob();
            defer blob.detach();
            defer encoder.deinit();

            const js_value = bun.FormData.toJS(
                globalObject,
                blob.slice(),
                encoder.encoding,
            ) catch |err| {
                return globalObject.ERR(
                    .FORMDATA_PARSE_ERROR,
                    "FormData parse error {s}",
                    .{
                        @errorName(err),
                    },
                ).reject();
            };

            return jsc.JSPromise.wrapValue(
                globalObject,
                js_value,
            );
        }

        pub fn getBlob(this: *Type, globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
            return getBlobWithThisValue(this, globalObject, callframe.this());
        }

        pub fn getBlobWithThisValue(this: *Type, globalObject: *jsc.JSGlobalObject, this_value: JSValue) bun.JSError!jsc.JSValue {
            var value: *Body.Value = this.getBodyValue();

            if (value.* == .Used) {
                return handleBodyAlreadyUsed(globalObject);
            }

            if (value.* == .Locked) {
                if (value.Locked.action != .none or
                    ((this_value != .zero and value.Locked.isDisturbed(Type, globalObject, this_value)) or
                        (this_value == .zero and value.Locked.readable.isDisturbed(globalObject))))
                {
                    return handleBodyAlreadyUsed(globalObject);
                }

                value.toBlobIfPossible();

                if (value.* == .Locked) {
                    return value.Locked.setPromise(globalObject, .{ .getBlob = {} });
                }
            }

            var blob = Blob.new(value.use());
            blob.allocator = bun.default_allocator;
            if (blob.content_type.len == 0) {
                if (this.getFetchHeaders()) |fetch_headers| {
                    if (fetch_headers.fastGet(.ContentType)) |content_type| {
                        var content_slice = content_type.toSlice(blob.allocator.?);
                        defer content_slice.deinit();
                        var allocated = false;
                        const mimeType = MimeType.init(content_slice.slice(), blob.allocator.?, &allocated);
                        blob.content_type = mimeType.value;
                        blob.content_type_allocated = allocated;
                        blob.content_type_was_set = true;
                        if (blob.store != null) {
                            blob.store.?.mime_type = mimeType;
                        }
                    }
                }
                if (!blob.content_type_was_set and blob.store != null) {
                    blob.content_type = MimeType.text.value;
                    blob.content_type_allocated = false;
                    blob.content_type_was_set = true;
                    blob.store.?.mime_type = MimeType.text;
                }
            }
            return jsc.JSPromise.resolvedPromiseValue(globalObject, blob.toJS(globalObject));
        }

        pub fn getBlobWithoutCallFrame(this: *Type, globalObject: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
            return getBlobWithThisValue(this, globalObject, .zero);
        }
    };
}

pub const ValueBufferer = struct {
    const log = bun.Output.scoped(.BodyValueBufferer, false);

    const ArrayBufferSink = bun.webcore.Sink.ArrayBufferSink;
    const Callback = *const fn (ctx: *anyopaque, bytes: []const u8, err: ?Body.Value.ValueError, is_async: bool) void;

    ctx: *anyopaque,
    onFinishedBuffering: Callback,

    js_sink: ?*ArrayBufferSink.JSSink = null,
    byte_stream: ?*jsc.WebCore.ByteStream = null,
    // readable stream strong ref to keep byte stream alive
    readable_stream_ref: jsc.WebCore.ReadableStream.Strong = .{},
    stream_buffer: bun.MutableString,
    allocator: std.mem.Allocator,
    global: *JSGlobalObject,

    pub fn deinit(this: *@This()) void {
        this.stream_buffer.deinit();
        if (this.byte_stream) |byte_stream| {
            byte_stream.unpipeWithoutDeref();
        }
        this.readable_stream_ref.deinit();

        if (this.js_sink) |buffer_stream| {
            buffer_stream.detach(this.global);
            buffer_stream.sink.destroy();
            this.js_sink = null;
        }
    }

    pub fn init(
        ctx: *anyopaque,
        onFinish: Callback,
        global: *JSGlobalObject,
        allocator: std.mem.Allocator,
    ) @This() {
        const this: ValueBufferer = .{
            .ctx = ctx,
            .onFinishedBuffering = onFinish,
            .allocator = allocator,
            .global = global,
            .stream_buffer = .{
                .allocator = allocator,
                .list = .{
                    .items = &.{},
                    .capacity = 0,
                },
            },
        };
        return this;
    }

    pub fn run(sink: *@This(), value: *jsc.WebCore.Body.Value) !void {
        value.toBlobIfPossible();

        switch (value.*) {
            .Used => {
                log("Used", .{});
                return error.StreamAlreadyUsed;
            },
            .Empty, .Null => {
                log("Empty", .{});
                return sink.onFinishedBuffering(sink.ctx, "", null, false);
            },

            .Error => |err| {
                log("Error", .{});
                sink.onFinishedBuffering(sink.ctx, "", err, false);
                return;
            },
            // .InlineBlob,
            .WTFStringImpl,
            .InternalBlob,
            .Blob,
            => {
                // toBlobIfPossible checks for WTFString needing a conversion.
                var input = value.useAsAnyBlobAllowNonUTF8String();
                const is_pending = input.needsToReadFile();
                defer if (!is_pending) input.detach();

                if (is_pending) {
                    input.Blob.doReadFileInternal(*@This(), sink, onFinishedLoadingFile, sink.global);
                } else {
                    const bytes = input.slice();
                    log("Blob {}", .{bytes.len});
                    sink.onFinishedBuffering(sink.ctx, bytes, null, false);
                }
                return;
            },
            .Locked => {
                try sink.bufferLockedBodyValue(value);
            },
        }
    }

    fn onFinishedLoadingFile(sink: *@This(), bytes: Blob.read_file.ReadFileResultType) void {
        switch (bytes) {
            .err => |err| {
                log("onFinishedLoadingFile Error", .{});
                sink.onFinishedBuffering(sink.ctx, "", .{ .SystemError = err }, true);
                return;
            },
            .result => |data| {
                log("onFinishedLoadingFile Data {}", .{data.buf.len});
                sink.onFinishedBuffering(sink.ctx, data.buf, null, true);
                if (data.is_temporary) {
                    bun.default_allocator.free(@constCast(data.buf));
                }
            },
        }
    }

    fn onStreamPipe(sink: *@This(), stream: jsc.WebCore.streams.Result, allocator: std.mem.Allocator) void {
        var stream_ = stream;
        const stream_needs_deinit = stream == .owned or stream == .owned_and_done;

        defer {
            if (stream_needs_deinit) {
                switch (stream_) {
                    .owned_and_done => |*owned| owned.listManaged(allocator).deinit(),
                    .owned => |*owned| owned.listManaged(allocator).deinit(),
                    else => unreachable,
                }
            }
        }

        const chunk = stream.slice();
        log("onStreamPipe chunk {}", .{chunk.len});
        _ = sink.stream_buffer.write(chunk) catch bun.outOfMemory();
        if (stream.isDone()) {
            const bytes = sink.stream_buffer.list.items;
            log("onStreamPipe done {}", .{bytes.len});
            sink.onFinishedBuffering(sink.ctx, bytes, null, true);
            return;
        }
    }

    pub fn onResolveStream(_: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
        var args = callframe.arguments_old(2);
        var sink: *@This() = args.ptr[args.len - 1].asPromisePtr(@This());
        sink.handleResolveStream(true);
        return .js_undefined;
    }

    pub fn onRejectStream(_: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
        const args = callframe.arguments_old(2);
        var sink = args.ptr[args.len - 1].asPromisePtr(@This());
        const err = args.ptr[0];
        sink.handleRejectStream(err, true);
        return .js_undefined;
    }

    fn handleRejectStream(sink: *@This(), err: JSValue, is_async: bool) void {
        if (sink.js_sink) |wrapper| {
            wrapper.detach(sink.global);
            sink.js_sink = null;
            wrapper.sink.destroy();
        }
        var ref = jsc.Strong.Optional.create(err, sink.global);
        defer ref.deinit();
        sink.onFinishedBuffering(sink.ctx, "", .{ .JSValue = ref }, is_async);
    }

    fn handleResolveStream(sink: *@This(), is_async: bool) void {
        if (sink.js_sink) |wrapper| {
            const bytes = wrapper.sink.bytes.slice();
            log("handleResolveStream {}", .{bytes.len});
            sink.onFinishedBuffering(sink.ctx, bytes, null, is_async);
        } else {
            log("handleResolveStream no sink", .{});
            sink.onFinishedBuffering(sink.ctx, "", null, is_async);
        }
    }

    fn createJSSink(sink: *@This(), stream: jsc.WebCore.ReadableStream) !void {
        stream.value.ensureStillAlive();
        var allocator = sink.allocator;
        var buffer_stream = try allocator.create(ArrayBufferSink.JSSink);
        var globalThis = sink.global;
        buffer_stream.* = ArrayBufferSink.JSSink{
            .sink = ArrayBufferSink{
                .bytes = bun.ByteList.init(&.{}),
                .allocator = allocator,
                .next = null,
            },
        };
        var signal = &buffer_stream.sink.signal;
        sink.js_sink = buffer_stream;

        signal.* = ArrayBufferSink.JSSink.SinkSignal.init(JSValue.zero);

        // explicitly set it to a dead pointer
        // we use this memory address to disable signals being sent
        signal.clear();
        assert(signal.isDead());

        const assignment_result: JSValue = ArrayBufferSink.JSSink.assignToStream(
            globalThis,
            stream.value,
            buffer_stream,
            @as(**anyopaque, @ptrCast(&signal.ptr)),
        );

        assignment_result.ensureStillAlive();

        // assert that it was updated
        assert(!signal.isDead());

        if (assignment_result.isError()) {
            return error.PipeFailed;
        }

        if (!assignment_result.isEmptyOrUndefinedOrNull()) {
            assignment_result.ensureStillAlive();
            // it returns a Promise when it goes through ReadableStreamDefaultReader
            if (assignment_result.asAnyPromise()) |promise| {
                switch (promise.status(globalThis.vm())) {
                    .Pending => {
                        assignment_result.then(
                            globalThis,
                            sink,
                            onResolveStream,
                            onRejectStream,
                        );
                    },
                    .Fulfilled => {
                        defer stream.value.unprotect();

                        sink.handleResolveStream(false);
                    },
                    .Rejected => {
                        defer stream.value.unprotect();

                        sink.handleRejectStream(promise.result(globalThis.vm()), false);
                    },
                }
                return;
            }
        }

        return error.PipeFailed;
    }

    fn bufferLockedBodyValue(sink: *@This(), value: *jsc.WebCore.Body.Value) !void {
        assert(value.* == .Locked);
        const locked = &value.Locked;
        if (locked.readable.get(sink.global)) |stream| {
            // keep the stream alive until we're done with it
            sink.readable_stream_ref = locked.readable;
            value.* = .{ .Used = {} };

            if (stream.isLocked(sink.global)) {
                return error.StreamAlreadyUsed;
            }

            switch (stream.ptr) {
                .Invalid => {
                    return error.InvalidStream;
                },
                // toBlobIfPossible should've caught this
                .Blob, .File => unreachable,
                .JavaScript, .Direct => {
                    // this is broken right now
                    // return sink.createJSSink(stream);
                    return error.UnsupportedStreamType;
                },
                .Bytes => |byte_stream| {
                    assert(byte_stream.pipe.ctx == null);
                    assert(sink.byte_stream == null);

                    const bytes = byte_stream.buffer.items;
                    // If we've received the complete body by the time this function is called
                    // we can avoid streaming it and just send it all at once.
                    if (byte_stream.has_received_last_chunk) {
                        log("byte stream has_received_last_chunk {}", .{bytes.len});
                        sink.onFinishedBuffering(sink.ctx, bytes, null, false);
                        // is safe to detach here because we're not going to receive any more data
                        stream.done(sink.global);
                        return;
                    }

                    byte_stream.pipe = jsc.WebCore.Pipe.Wrap(@This(), onStreamPipe).init(sink);
                    sink.byte_stream = byte_stream;
                    log("byte stream pre-buffered {}", .{bytes.len});

                    _ = sink.stream_buffer.write(bytes) catch bun.outOfMemory();
                    return;
                },
            }
        }

        if (locked.onReceiveValue != null or locked.task != null) {
            // someone else is waiting for the stream or waiting for `onStartStreaming`
            const readable = try value.toReadableStream(sink.global);
            readable.ensureStillAlive();
            readable.protect();
            return try sink.bufferLockedBodyValue(value);
        }
        // is safe to wait it buffer
        locked.task = @ptrCast(sink);
        locked.onReceiveValue = @This().onReceiveValue;
    }

    fn onReceiveValue(ctx: *anyopaque, value: *jsc.WebCore.Body.Value) void {
        const sink = bun.cast(*@This(), ctx);
        switch (value.*) {
            .Error => |err| {
                log("onReceiveValue Error", .{});
                sink.onFinishedBuffering(sink.ctx, "", err, true);
                return;
            },
            else => {
                value.toBlobIfPossible();
                var input = value.useAsAnyBlobAllowNonUTF8String();
                const bytes = input.slice();
                log("onReceiveValue {}", .{bytes.len});
                sink.onFinishedBuffering(sink.ctx, bytes, null, true);
            },
        }
    }

    comptime {
        const jsonResolveStream = jsc.toJSHostFn(onResolveStream);
        @export(&jsonResolveStream, .{ .name = "Bun__BodyValueBufferer__onResolveStream" });
        const jsonRejectStream = jsc.toJSHostFn(onRejectStream);
        @export(&jsonRejectStream, .{ .name = "Bun__BodyValueBufferer__onRejectStream" });
    }
};

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const MutableString = bun.MutableString;
const Output = bun.Output;
const assert = bun.assert;
const default_allocator = bun.default_allocator;
const strings = bun.strings;
const FetchHeaders = bun.webcore.FetchHeaders;
const MimeType = bun.http.MimeType;

const jsc = bun.jsc;
const ArrayBuffer = jsc.ArrayBuffer;
const JSGlobalObject = jsc.JSGlobalObject;
const JSPromise = jsc.JSPromise;
const JSValue = jsc.JSValue;
const SystemError = jsc.SystemError;
const VirtualMachine = jsc.VirtualMachine;
const ZigString = jsc.ZigString;

const Response = jsc.WebCore.Response;
const streams = jsc.WebCore.streams;

const Blob = jsc.WebCore.Blob;
const AnyBlob = Blob.Any;
const InternalBlob = Blob.Internal;
