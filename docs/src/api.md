# API

The user-facing surface is intentionally small: run a server, run the
all-in-one dev rig, and wait on either.

```@docs
BonitoAgents.serve
BonitoAgents.dev_server
BonitoAgents.wait!
```

## Everything else

```@autodocs
Modules = [BonitoAgents]
Order   = [:module, :constant, :type, :function, :macro]
Public  = true
Private = false
Filter  = t -> !(t in (BonitoAgents.serve, BonitoAgents.dev_server, BonitoAgents.wait!))
```
