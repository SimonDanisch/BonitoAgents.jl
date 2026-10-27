register!("bt_chat", """
Discover and message other BonitoAgents chats when the user authorized coordination.
Chat messaging is OFF by default. The user must enable 'Chat messaging' in BOTH
chats' ⋯ menus. Dev mode does not enable it. The server checks the switches on
every call; disabling either one blocks new messages and pauses unsubmitted ones.
Do not try to bypass an off switch or enable it yourself.

action="list" returns this chat's enabled state and its available peer chats
(project_id, title, worker). Only opted-in chats belonging to the same user are
listed. action="send" takes project_id and text. It queues after the current
message of a busy agent, using the same delivery/steering path as user input.
The reply says status="queued": acceptance is NOT confirmation that the agent
received/read the message or finished work. Replies appear in the receiving
chat; that agent can use this same tool to reply. Sender identity and server UTC
timestamps are attached automatically. Use one clear message, not polling/spam.
""", Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}(
    "action" => Dict("type" => "string", "enum" => ["list", "send"], "default" => "list"),
    "project_id" => Dict("type" => "string", "description" => "Receiving chat id from action=list"),
    "text" => Dict("type" => "string", "description" => "Message body for action=send"))),
    function(args::AbstractDict)
        result = dev_call("chat_messaging"; action = String(get(args, "action", "list")),
            project_id = String(get(args, "project_id", "")), text = String(get(args, "text", "")))
        if !result["isError"]
            # JSON keys and worker paths must remain literal in chat Markdown.
            block = only(result["content"])
            block["text"] = "```json\n" * block["text"] * "\n```"
        end
        return result
    end)
