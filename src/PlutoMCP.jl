module PlutoMCP

using JSON3
using UUIDs
using HTTP
using Pluto

include("Output.jl")
include("Context.jl")
include("Staging.jl")
include("Projection.jl")
include("Tools.jl")
include("Graph.jl")
include("EvalLog.jl")
include("Lifecycle.jl")
include("MCP.jl")
include("Server.jl")

register_http_bridge!(_run_http_mcp_server)

export serve, connect

end
