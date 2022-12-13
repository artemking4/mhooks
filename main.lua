local mhooks = require "mhooks"
local hook = mhooks:new "Global"

local event2 = hook:event {
    name = "event2"
}

local event3 = hook:event {
    name = "event3"
}

hook {
    name = "hook",

    targets = {
        mhooks.either("event", "event2"),
        "event3"
    },

    function(evt, hookinfo)
        --p("hook called", evt.args, hookinfo.target)
    end
}

hook {
    name = "hook_on_hook",

    target = mhooks.enforce("hook"),

    function(evt, hookinfo)
        --p("hook on hook called", evt.args, hookinfo.target)
    end
}

local event = hook:event {
    name = "event"
}

for i = 1, 100 do
    local reps = 10 ^ i
    p("running perf test", reps)
    local start = os.clock()

    for i = 1, reps do
        event { 
            message = "wyd"
        }
    end
    p("done, took", os.clock() - start)
end
