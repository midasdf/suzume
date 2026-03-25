(function() {
    var props = {
        output: %(output)d,
        timeout_multiplier: %(timeout_multiplier)s,
        explicit_timeout: %(explicit_timeout)s,
        debug: %(debug)s
    };
    setup(props);

    add_completion_callback(function(tests, harness_status) {
        var loc = location;
        var id = decodeURIComponent(loc.pathname || "") +
                 decodeURIComponent(loc.search || "") +
                 decodeURIComponent(loc.hash || "");
        var result = JSON.stringify([
            id,
            harness_status.status,
            harness_status.message || "",
            harness_status.stack || "",
            tests.map(function(t) {
                return [t.name, t.status, t.message || "", t.stack || ""];
            })
        ]);
        console.log("ALERT: RESULT: " + result);
    });
})();
