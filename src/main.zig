/// Emacs dynamic module entry point for parinfer-rust.
const emacs = @import("emacs.zig");
const emacs_wrapper = @import("emacs_wrapper.zig");

/// Required by Emacs to verify GPL compatibility.
export var plugin_is_GPL_compatible: c_int = 0;

/// Entry point called by Emacs when the module is loaded.
export fn emacs_module_init(runtime: *emacs.Runtime) c_int {
    const env = runtime.get_environment(runtime);
    emacs_wrapper.init(env);
    return 0;
}
