-- warning: contains quite a bit of shitcode in some places because of premature optimization and bad architectural planning
-- should be fine tho

---@class Event
---@field name string
---@field hooks HookInfo[] index < 0 = pre, index > 0 = post
---@field _prehooks HookInfo[]
---@field _posthooks HookInfo[]
---@field call fun(self, args: table):any
---@field callForSignal fun(self, signal: Signal, hookinfo: HookInfo?):any
---@field runPostHooks fun(self, signal: Signal):boolean
---@field runPreHooks fun(self, signal: Signal):boolean
---@field addHook fun(self, info: HookInfo)
---@field removeHook fun(self, target: HookTarget)

-- gets passed through a hook chain as a description of whatever event that happened
---@class Signal
---@field event Event
---@field args table
---@field result any?

---@alias FoldFunction fun(tree, hooks: HookManager, reference: fun(name: string)): HookTarget[]
---@alias HookCallback fun(info: Signal, hookinfo: HookInfo):boolean?

---@class Hook : Event
---@field callback HookCallback
---@field retarget fun(fold: FoldFunction, hooks: HookManager, reference: fun(name: string)):HookTarget[]
---@field update fun(self, init: boolean?)
---@field targets HookTarget[]
---@field binds Bind[] what events is this hook bound to, needed to rebind stuff

---@class HookManager
---@field name string 
---@field references table<string, Hook[]> if something updates, we can look it up in this table and see what we need to remove/restructurize
---@field events Event[]

---@class HookTarget
---@field name string target event name
---@field priority number = 0, higher = closer to pos 0
---@field position integer = 1, the position

---@class HookInfo
---@field target HookTarget
---@field hook Hook

---@class Bind
---@field target HookTarget
---@field event Event

---@class EventParams
---@field name string

---@class HookParams : EventParams
---@field targets table
---@field callback HookCallback

local mhooks = { }

local hookTargetMeta = { type = "HookTarget" }
function hookTargetMeta.__eq(x, y)
    return x.name == y.name
        and x.priority == y.priority
        and x.position == y.position
end

---@param target string
---@return HookTarget
function mhooks.hookTarget(target, priority, position)
    return setmetatable({
        name = target,
        priority = priority or 0,
        position = position or 1
    }, hookTargetMeta)
end

function mhooks.isHookTarget(t)
    return getmetatable(t) == hookTargetMeta
end

local function foldTargetTree(tree, hooks, reference)
    local output = { }

    local function processValue(v)
        local t = type(v)
        if t == "string" then
            if reference then reference(v) end
            if hooks:getEvent(v) then
                table.insert(output, mhooks.hookTarget(v))
            end
        elseif t == "function" then
            for k, v in ipairs(foldTargetTree(v(foldTargetTree, hooks, reference), hooks, reference)) do
                table.insert(output, v)
            end
        elseif t == "table" then
            if mhooks.isHookTarget(v) then 
                table.insert(output, v)
            else
                for k, v in ipairs(foldTargetTree(v, hooks, reference)) do
                    table.insert(output, v)
                end
            end
        end
    end

    if type(tree) == "table" and not mhooks.isHookTarget(tree) then
        for k,v in ipairs(tree) do 
            processValue(v)
        end
    else
        processValue(tree)
    end

    return output
end

function mhooks.either(...)
    local targets = { ... }
    return function(fold, hooks, reference)
        return fold(targets, hooks, reference)[1]
    end
end

function mhooks.enforce(...)
    local targets = { ... }
    return function(fold, hooks, reference)
        local t = fold(targets, hooks, reference)
        assert(#t ~= 0, "Failed to enforce a hook")
        return t
    end
end

function mhooks:new(name)
    ---@type HookManager
    local hook = {
        name = name,
        references = { },
        events = { }
    }

    function hook:getEvent(name)
        for k,v in ipairs(self.events) do 
            if v.name == name then 
                return v
            end
        end
    end

    function hook:addEvent(event)
        table.insert(self.events, event)
        local refs = self.references[event.name]
        if refs then 
            for k,v in ipairs(refs) do 
                v:update()
            end
        end
    end

    function hook:event(options)
        ---@type Event
        local event = {
            name = options.name,
            hooks = { },

            -- ugly but fine i guess
            _prehooks = { }, -- iterated backwards
            _posthooks = { }
        }

        local function remove(tbl, val)
            -- this should be fine as we dont remove anything we havent checked yet
            for i = #tbl, 1, -1 do 
                if tbl[i] == val then 
                    table.remove(tbl, i)
                end
            end
        end

        function event:removeHook(hook)
            remove(self._prehooks, hook)
            remove(self._posthooks, hook)
        end

        function event:addHook(info)
            assert(info.target.position ~= 0)
            local t = info.target.position > 0 and self._posthooks or self._prehooks

            table.insert(t, info)
            table.sort(t, function(a, b)
                a = a.target
                b = b.target

                if a.position ~= b.position then 
                    return a.position < b.position
                end
            
                return a.priority > b.priority
            end)
        end

        function event:runPreHooks(signal)
            for i = #self._prehooks, 1, -1 do 
                local v = self._prehooks[i]
                if v.hook:callForSignal(signal, v) then 
                    return true
                end
            end

            return false
        end

        function event:runPostHooks(signal)
            for i = 1, #self._posthooks do 
                local v = self._posthooks[i]
                if v.hook:callForSignal(signal, v) then 
                    return true
                end
            end

            return false
        end

        function event:callForSignal(signal)
            if not self:runPreHooks(signal) then 
                self:runPostHooks(signal)
            end

            return signal.result
        end

        function event:call(args) 
            local signal = {
                event = event,
                args = args,
                result = nil
            }

            return self:callForSignal(signal)
        end

        setmetatable(event, {
            __call = function(t, args)
                return event:call(args)
            end
        })

        self:addEvent(event)
        return event
    end

    local function getDiff(old, new)
        local similarities = { }
        local differences = { }

        for xk,xv in ipairs(old) do
            local r 
            for yk,yv in ipairs(new) do 
                if xv == yv then 
                    r = yv
                    break
                end
            end

            if not r then 
                differences[xv] = true
            else
                similarities[r] = true
            end
        end

        return differences, similarities
    end

    function hook:hook(options)
        local event = self:event(options)
        ---@cast event Hook

        event.callback = assert(options[1] or options.callback)
        local targets = assert(options.target or options.targets)
        event.retarget = function(fold, hooks, reference)
            return fold(targets, hooks, reference)
        end

        function event:callForSignal(signal, info) 
            if not self:runPreHooks(signal) then 
                self.callback(signal, info)
                self:runPostHooks(signal)
            end

            return signal.output
        end

        function event:call()
            error "Do not manually call hooks"
        end

        local function addReference(ref)
            if not hook.references[ref] then hook.references[ref] = { } end
            table.insert(hook.references[ref], event)
        end

        function event:update(init)
            local ref
            if init then 
                ref = addReference
            end

            local targets = self.retarget(foldTargetTree, hook, ref)
            local old = self.targets
            local dif, sim
            if old then
                dif, sim = getDiff(old, targets)
            end

            self.targets = targets

            if dif then
                for k,v in pairs(dif) do 
                    hook:getEvent(k.name):removeHook(k)
                end
            end

            for k,v in ipairs(targets) do 
                if not sim or not sim[v] then
                    local evt = hook:getEvent(v.name)

                    evt:addHook({
                        hook = self,
                        target = v
                    })
                end
            end
        end
        event:update(true)

        return event
    end

    setmetatable(hook, {
        __call = function(t, options)
            local type = options.type or "hook"

            if type == "hook" then 
                return hook:hook(options)
            elseif type == "event" then
                return hook:event(options)
            end

            error("Bad type")
        end
    })

    return hook
end

return mhooks