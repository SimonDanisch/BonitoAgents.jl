module HelloApp

import BonitoAgents
using BonitoAgents: AgentApp, AppContext, AppTool, Param, AppCall,
                    ChatHeader, ChatTranscript, ChatComposer
using Bonito

struct Hello <: AgentApp
    ctx::AppContext
end

BonitoAgents.app_id(::Type{Hello}) = "hello"
BonitoAgents.app_title(::Hello) = "Hello"
BonitoAgents.app_tools(::Hello) = [AppTool(:hello_greet, "Greet someone.", (name = Param(String, "Who."),))]
BonitoAgents.call_tool(::Hello, ::Val{:hello_greet}, call::AppCall) = "Hello, $(call.args.name)!"
BonitoAgents.chat_pane(::Hello, view) =
    (ChatHeader(view), DOM.div("The Hello app's own pane"; class = "hello-pane"),
     ChatTranscript(view), ChatComposer(view))

function __init__()
    BonitoAgents.register_app!(Hello)
end

end
