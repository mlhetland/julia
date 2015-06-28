# This file is a part of Julia. License is MIT: http://julialang.org/license

abstract AbstractCmd

type Cmd <: AbstractCmd
    exec::Vector{ByteString}
    ignorestatus::Bool
    detach::Bool
    env::Union{Array{ByteString},Void}
    dir::UTF8String
    Cmd(exec::Vector{ByteString}) = new(exec, false, false, nothing, "")
end

type OrCmds <: AbstractCmd
    a::AbstractCmd
    b::AbstractCmd
    OrCmds(a::AbstractCmd, b::AbstractCmd) = new(a, b)
end

type ErrOrCmds <: AbstractCmd
    a::AbstractCmd
    b::AbstractCmd
    ErrOrCmds(a::AbstractCmd, b::AbstractCmd) = new(a, b)
end

type AndCmds <: AbstractCmd
    a::AbstractCmd
    b::AbstractCmd
    AndCmds(a::AbstractCmd, b::AbstractCmd) = new(a, b)
end

shell_escape(cmd::Cmd) = shell_escape(cmd.exec...)

function show(io::IO, cmd::Cmd)
    print_env = cmd.env !== nothing
    print_dir = !isempty(cmd.dir)
    (print_env || print_dir) && print(io, "setenv(")
    esc = shell_escape(cmd)
    print(io, '`')
    for c in esc
        if c == '`'
            print(io, '\\')
        end
        print(io, c)
    end
    print(io, '`')
    print_env && (print(io, ","); show(io, cmd.env))
    print_dir && (print(io, "; dir="); show(io, cmd.dir))
    (print_dir || print_env) && print(io, ")")
end

function show(io::IO, cmds::Union{OrCmds,ErrOrCmds})
    print(io, "pipe(")
    show(io, cmds.a)
    print(io, ", ")
    print(io, isa(cmds, ErrOrCmds) ? "stderr=" : "stdout=")
    show(io, cmds.b)
    print(io, ")")
end

function show(io::IO, cmds::AndCmds)
    show(io, cmds.a)
    print(io, " & ")
    show(io, cmds.b)
end

const STDIN_NO  = 0
const STDOUT_NO = 1
const STDERR_NO = 2

immutable FileRedirect
    filename::AbstractString
    append::Bool
    function FileRedirect(filename, append)
        if lowercase(filename) == (@unix? "/dev/null" : "nul")
            warn_once("for portability use DevNull instead of a file redirect")
        end
        new(filename, append)
    end
end

immutable DevNullStream <: AsyncStream end
const DevNull = DevNullStream()
copy(::DevNullStream) = DevNull
uvhandle(::DevNullStream) = C_NULL
uvhandle(x::Ptr) = x
uvtype(::Ptr) = UV_STREAM
uvtype(::DevNullStream) = UV_STREAM

# Not actually a pointer, but that's how we pass it through the C API so it's fine
uvhandle(x::RawFD) = convert(Ptr{Void}, x.fd % UInt)
uvtype(x::RawFD) = UV_RAW_FD

typealias Redirectable Union{AsyncStream, FS.File, FileRedirect, DevNullStream, IOStream, RawFD}

type CmdRedirect <: AbstractCmd
    cmd::AbstractCmd
    handle::Redirectable
    stream_no::Int
end

function show(io::IO, cr::CmdRedirect)
    print(io, "pipe(")
    show(io, cr.cmd)
    print(io, ", ")
    if cr.stream_no == STDOUT_NO
        print(io, "stdout=")
    elseif cr.stream_no == STDERR_NO
        print(io, "stderr=")
    elseif cr.stream_no == STDIN_NO
        print(io, "stdin=")
    end
    show(io, cr.handle)
    print(io, ")")
end


ignorestatus(cmd::Cmd) = (cmd.ignorestatus=true; cmd)
ignorestatus(cmd::Union{OrCmds,AndCmds}) = (ignorestatus(cmd.a); ignorestatus(cmd.b); cmd)
detach(cmd::Cmd) = (cmd.detach=true; cmd)

# like bytestring(s), but throw an error if s contains NUL, since
# libuv requires NUL-terminated strings
function cstr(s)
    if Base.containsnul(s)
        throw(ArgumentError("strings containing NUL cannot be passed to spawned processes"))
    end
    return bytestring(s)
end

setenv{S<:ByteString}(cmd::Cmd, env::Array{S}; dir="") = (cmd.env = ByteString[cstr(x) for x in env]; setenv(cmd, dir=dir); cmd)
setenv(cmd::Cmd, env::Associative; dir="") = (cmd.env = ByteString[cstr(string(k)*"="*string(v)) for (k,v) in env]; setenv(cmd, dir=dir); cmd)
setenv{T<:AbstractString}(cmd::Cmd, env::Pair{T}...; dir="") = (cmd.env = ByteString[cstr(k*"="*string(v)) for (k,v) in env]; setenv(cmd, dir=dir); cmd)
setenv(cmd::Cmd; dir="") = (cmd.dir = cstr(dir); cmd)

(&)(left::AbstractCmd, right::AbstractCmd) = AndCmds(left, right)
redir_out(src::AbstractCmd, dest::AbstractCmd) = OrCmds(src, dest)
redir_err(src::AbstractCmd, dest::AbstractCmd) = ErrOrCmds(src, dest)

# Stream Redirects
redir_out(dest::Redirectable, src::AbstractCmd) = CmdRedirect(src, dest, STDIN_NO)
redir_out(src::AbstractCmd, dest::Redirectable) = CmdRedirect(src, dest, STDOUT_NO)
redir_err(src::AbstractCmd, dest::Redirectable) = CmdRedirect(src, dest, STDERR_NO)

# File redirects
redir_out(src::AbstractCmd, dest::AbstractString) = CmdRedirect(src, FileRedirect(dest, false), STDOUT_NO)
redir_out(src::AbstractString, dest::AbstractCmd) = CmdRedirect(dest, FileRedirect(src, false), STDIN_NO)
redir_err(src::AbstractCmd, dest::AbstractString) = CmdRedirect(src, FileRedirect(dest, false), STDERR_NO)
redir_out_append(src::AbstractCmd, dest::AbstractString) = CmdRedirect(src, FileRedirect(dest, true), STDOUT_NO)
redir_err_append(src::AbstractCmd, dest::AbstractString) = CmdRedirect(src, FileRedirect(dest, true), STDERR_NO)

function pipe(cmd::AbstractCmd; stdin=nothing, stdout=nothing, stderr=nothing, append::Bool=false)
    if append && stdout === nothing && stderr === nothing
        error("append set to true, but no output redirections specified")
    end
    if stdin !== nothing
        cmd = redir_out(stdin, cmd)
    end
    if stdout !== nothing
        cmd = append ? redir_out_append(cmd, stdout) : redir_out(cmd, stdout)
    end
    if stderr !== nothing
        cmd = append ? redir_err_append(cmd, stderr) : redir_err(cmd, stderr)
    end
    return cmd
end

pipe(cmd::AbstractCmd, dest) = pipe(cmd, stdout=dest)
pipe(src::Union{Redirectable,AbstractString}, cmd::AbstractCmd) = pipe(cmd, stdin=src)

pipe(a, b, c, d...) = pipe(pipe(a,b), c, d...)

typealias RawOrBoxedHandle Union{UVHandle,AsyncStream,Redirectable,IOStream}
typealias StdIOSet NTuple{3,RawOrBoxedHandle}

type Process
    cmd::Cmd
    handle::Ptr{Void}
    in::AsyncStream
    out::AsyncStream
    err::AsyncStream
    exitcode::Int32
    termsignal::Int32
    exitcb::Callback
    exitnotify::Condition
    closecb::Callback
    closenotify::Condition
    function Process(cmd::Cmd, handle::Ptr{Void}, in::RawOrBoxedHandle, out::RawOrBoxedHandle, err::RawOrBoxedHandle)
        if !isa(in, AsyncStream) || in === DevNull
            in=DevNull
        end
        if !isa(out, AsyncStream) || out === DevNull
            out=DevNull
        end
        if !isa(err, AsyncStream) || err === DevNull
            err=DevNull
        end
        this = new(cmd, handle, in, out, err, typemin(Int32), typemin(Int32), false, Condition(), false, Condition())
        finalizer(this, uvfinalize)
        this
    end
end

type ProcessChain
    processes::Vector{Process}
    in::Redirectable
    out::Redirectable
    err::Redirectable
    ProcessChain(stdios::StdIOSet) = new(Process[], stdios[1], stdios[2], stdios[3])
end
typealias ProcessChainOrNot Union{Bool,ProcessChain}

function _jl_spawn(cmd, argv, loop::Ptr{Void}, pp::Process,
                   in, out, err)
    proc = Libc.malloc(_sizeof_uv_process)
    disassociate_julia_struct(proc)
    error = ccall(:jl_spawn, Int32,
        (Ptr{UInt8}, Ptr{Ptr{UInt8}}, Ptr{Void}, Ptr{Void}, Any, Int32,
         Ptr{Void}, Int32, Ptr{Void}, Int32, Ptr{Void}, Int32, Ptr{Ptr{UInt8}}, Ptr{UInt8}, Ptr{Void}),
        cmd, argv, loop, proc, pp, uvtype(in),
        uvhandle(in), uvtype(out), uvhandle(out), uvtype(err), uvhandle(err),
        pp.cmd.detach, pp.cmd.env === nothing ? C_NULL : pp.cmd.env, isempty(pp.cmd.dir) ? C_NULL : pp.cmd.dir,
        uv_jl_return_spawn::Ptr{Void})
    if error != 0
        ccall(:jl_forceclose_uv, Void, (Ptr{Void},), proc)
        throw(UVError("could not spawn "*string(pp.cmd), error))
    end
    associate_julia_struct(proc, pp)
    return proc
end

function uvfinalize(proc::Process)
    proc.handle != C_NULL && ccall(:jl_close_uv, Void, (Ptr{Void},), proc.handle)
    disassociate_julia_struct(proc)
    proc.handle = C_NULL
end

function uv_return_spawn(p::Ptr{Void}, exit_status::Int64, termsignal::Int32)
    data = ccall(:jl_uv_process_data, Ptr{Void}, (Ptr{Void},), p)
    data == C_NULL && return
    proc = unsafe_pointer_to_objref(data)::Process
    proc.exitcode = Int32(exit_status)
    proc.termsignal = termsignal
    if isa(proc.exitcb, Function) proc.exitcb(proc, exit_status, termsignal) end
    ccall(:jl_close_uv, Void, (Ptr{Void},), proc.handle)
    notify(proc.exitnotify)
    nothing
end

function _uv_hook_close(proc::Process)
    proc.handle = C_NULL
    if isa(proc.closecb, Function) proc.closecb(proc) end
    notify(proc.closenotify)
end

function spawn(pc::ProcessChainOrNot, redirect::CmdRedirect, stdios::StdIOSet, exitcb::Callback, closecb::Callback)
    spawn(pc, redirect.cmd, (redirect.stream_no == STDIN_NO  ? redirect.handle : stdios[1],
                             redirect.stream_no == STDOUT_NO ? redirect.handle : stdios[2],
                             redirect.stream_no == STDERR_NO ? redirect.handle : stdios[3]), exitcb, closecb)
end

function spawn(pc::ProcessChainOrNot, cmds::OrCmds, stdios::StdIOSet, exitcb::Callback, closecb::Callback)
    out_pipe = box(Ptr{Void}, Intrinsics.jl_alloca(_sizeof_uv_named_pipe))
    in_pipe = box(Ptr{Void}, Intrinsics.jl_alloca(_sizeof_uv_named_pipe))
    #out_pipe = Libc.malloc(_sizeof_uv_named_pipe)
    #in_pipe = Libc.malloc(_sizeof_uv_named_pipe)
    link_pipe(in_pipe, false, out_pipe, false)
    if pc == false
        pc = ProcessChain(stdios)
    end
    try
        spawn(pc, cmds.a, (stdios[1], out_pipe, stdios[3]), exitcb, closecb)
        spawn(pc, cmds.b, (in_pipe, stdios[2], stdios[3]), exitcb, closecb)
    catch err
        close_pipe_sync(out_pipe)
        close_pipe_sync(in_pipe)
        rethrow(err)
    end
    close_pipe_sync(out_pipe)
    close_pipe_sync(in_pipe)
    pc
end

function spawn(pc::ProcessChainOrNot, cmds::ErrOrCmds, stdios::StdIOSet, exitcb::Callback, closecb::Callback)
    out_pipe = box(Ptr{Void}, Intrinsics.jl_alloca(_sizeof_uv_named_pipe))
    in_pipe = box(Ptr{Void}, Intrinsics.jl_alloca(_sizeof_uv_named_pipe))
    #out_pipe = Libc.malloc(_sizeof_uv_named_pipe)
    #in_pipe = Libc.malloc(_sizeof_uv_named_pipe)
    link_pipe(in_pipe, false, out_pipe, false)
    if pc == false
        pc = ProcessChain(stdios)
    end
    try
        spawn(pc, cmds.a, (stdios[1], stdios[2], out_pipe), exitcb, closecb)
        spawn(pc, cmds.b, (in_pipe, stdios[2], stdios[3]), exitcb, closecb)
    catch err
        close_pipe_sync(out_pipe)
        close_pipe_sync(in_pipe)
        rethrow(err)
    end
    close_pipe_sync(out_pipe)
    close_pipe_sync(in_pipe)
    pc
end


macro setup_stdio()
    esc(
    quote
        close_in,close_out,close_err = false,false,false
        in,out,err = stdios
        if isa(stdios[1], Pipe)
            if stdios[1].handle == C_NULL
                in = box(Ptr{Void},Intrinsics.jl_alloca(_sizeof_uv_named_pipe))
                link_pipe(in,false,stdios[1],true)
                close_in = true
            end
        elseif isa(stdios[1], FileRedirect)
            in = FS.open(stdios[1].filename, JL_O_RDONLY)
            close_in = true
        elseif isa(stdios[1], IOStream)
            in = FS.File(RawFD(fd(stdios[1])))
        end
        if isa(stdios[2], Pipe)
            if stdios[2].handle == C_NULL
                out = box(Ptr{Void},Intrinsics.jl_alloca(_sizeof_uv_named_pipe))
                link_pipe(stdios[2],true,out,false)
                close_out = true
            end
        elseif isa(stdios[2], FileRedirect)
            out = FS.open(stdios[2].filename, JL_O_WRONLY | JL_O_CREAT | (stdios[2].append?JL_O_APPEND:JL_O_TRUNC), S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            close_out = true
        elseif isa(stdios[2], IOStream)
            out = FS.File(RawFD(fd(stdios[2])))
        end
        if isa(stdios[3], Pipe)
            if stdios[3].handle == C_NULL
                err = box(Ptr{Void},Intrinsics.jl_alloca(_sizeof_uv_named_pipe))
                link_pipe(stdios[3],true,err,false)
                close_err = true
            end
        elseif isa(stdios[3], FileRedirect)
            err = FS.open(stdios[3].filename, JL_O_WRONLY | JL_O_CREAT | (stdios[3].append?JL_O_APPEND:JL_O_TRUNC), S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            close_err = true
        elseif isa(stdios[3], IOStream)
            err = FS.File(RawFD(fd(stdios[3])))
        end
    end)
end

macro cleanup_stdio()
    esc(
    quote
        close_in && (isa(in,Ptr) ? close_pipe_sync(in) : close(in))
        close_out && (isa(out,Ptr) ? close_pipe_sync(out) : close(out))
        close_err && (isa(err,Ptr) ? close_pipe_sync(err) : close(err))
    end)
end

function spawn(pc::ProcessChainOrNot, cmd::Cmd, stdios::StdIOSet, exitcb::Callback, closecb::Callback)
    loop = eventloop()
    pp = Process(cmd, C_NULL, stdios[1], stdios[2], stdios[3]);
    @setup_stdio
    pp.exitcb = exitcb
    pp.closecb = closecb
    pp.handle = _jl_spawn(cmd.exec[1], cmd.exec, loop, pp,
                          in, out, err)
    @cleanup_stdio
    if isa(pc, ProcessChain)
        push!(pc.processes, pp)
    end
    pp
end

function spawn(pc::ProcessChainOrNot, cmds::AndCmds, stdios::StdIOSet, exitcb::Callback, closecb::Callback)
    if pc == false
        pc = ProcessChain(stdios)
    end
    @setup_stdio
    spawn(pc, cmds.a, (in,out,err), exitcb, closecb)
    spawn(pc, cmds.b, (in,out,err), exitcb, closecb)
    @cleanup_stdio
    pc
end

# INTERNAL
# returns a tuple of function arguments to spawn:
# (stdios, exitcb, closecb)
# |       |        \ The function to be called once the uv handle is closed
# |       \ The function to be called once the process exits
# \ A set of up to 256 stdio instructions, where each entry can be either:
#   | - An AsyncStream to be passed to the child
#   | - DevNull to pass /dev/null
#   | - An FS.File object to redirect the output to
#   \ - An ASCIIString specifying a filename to be opened

spawn_opts_swallow(stdios::StdIOSet, exitcb::Callback=false, closecb::Callback=false) =
    (stdios,exitcb,closecb)
spawn_opts_swallow(in::Redirectable=DevNull, out::Redirectable=DevNull, err::Redirectable=DevNull, args...) =
    (tuple(in,out,err,args...),false,false)
spawn_opts_inherit(stdios::StdIOSet, exitcb::Callback=false, closecb::Callback=false) =
    (stdios,exitcb,closecb)
# pass original descriptors to child processes by default, because we might
# have already exhausted and closed the libuv object for our standard streams.
# this caused issue #8529.
spawn_opts_inherit(in::Redirectable=RawFD(0), out::Redirectable=RawFD(1), err::Redirectable=RawFD(2), args...) =
    (tuple(in,out,err,args...),false,false)

spawn(pc::ProcessChainOrNot, cmds::AbstractCmd, args...) = spawn(pc, cmds, spawn_opts_swallow(args...)...)
spawn(cmds::AbstractCmd, args...) = spawn(false, cmds, spawn_opts_swallow(args...)...)

macro tmp_rpipe(pipe, tmppipe, code, args...)
    esc(quote
        $pipe = Pipe(C_NULL)
        $tmppipe = Pipe(C_NULL)
        link_pipe($pipe, true, $tmppipe, false)
        r = begin
            $code
        end
        close_pipe_sync($tmppipe)
        r
    end)
end

macro tmp_wpipe(tmppipe, pipe, code)
    esc(quote
        $pipe = Pipe(C_NULL)
        $tmppipe = Pipe(C_NULL)
        link_pipe($tmppipe, false, $pipe, true)
        r = begin
            $code
        end
        close_pipe_sync($tmppipe)
        r
    end)
end

function eachline(cmd::AbstractCmd, stdin)
    @tmp_rpipe out tmp begin
        processes = spawn(false, cmd, (stdin,tmp,STDERR))
        # implicitly close after reading lines, since we opened
        EachLine(out, ()->close(out))
    end
end
eachline(cmd::AbstractCmd) = eachline(cmd, DevNull)

# return a (Pipe,Process) pair to write/read to/from the pipeline
function open(cmds::AbstractCmd, mode::AbstractString="r", stdio::AsyncStream=DevNull)
    if mode == "r"
        processes = @tmp_rpipe out tmp spawn(false, cmds, (stdio,tmp,STDERR))
        (out, processes)
    elseif mode == "w"
        processes = @tmp_wpipe tmp inpipe spawn(false, cmds, (tmp,stdio,STDERR))
        (inpipe, processes)
    else
        throw(ArgumentError("mode must be \"r\" or \"w\", not \"$mode\""))
    end
end

function open(f::Function, cmds::AbstractCmd, args...)
    io, P = open(cmds, args...)
    ret = try
        f(io)
    catch
        kill(P)
        rethrow()
    finally
        close(io)
    end
    success(P) || pipeline_error(P)
    return ret
end

# TODO: convert this to use open(cmd, "r+"), with a single read/write pipe
function readandwrite(cmds::AbstractCmd)
    (out, processes) = @tmp_wpipe tmp inpipe open(cmds, "r", tmp)
    (out, inpipe, processes)
end

function readbytes(cmd::AbstractCmd, stdin::AsyncStream=DevNull)
    (out,pc) = open(cmd, "r", stdin)
    bytes = readbytes(out)
    !success(pc) && pipeline_error(pc)
    return bytes
end

function readall(cmd::AbstractCmd, stdin::AsyncStream=DevNull)
    return bytestring(readbytes(cmd, stdin))
end

function writeall(cmd::AbstractCmd, stdin::AbstractString, stdout::AsyncStream=DevNull)
    open(cmd, "w", stdout) do io
        write(io, stdin)
    end
end

function run(cmds::AbstractCmd, args...)
    ps = spawn(cmds, spawn_opts_inherit(args...)...)
    success(ps) ? nothing : pipeline_error(ps)
end

const SIGPIPE = 13
function test_success(proc::Process)
    assert(process_exited(proc))
    if proc.exitcode < 0
        #TODO: this codepath is not currently tested
        throw(UVError("could not start process $(string(proc.cmd))", proc.exitcode))
    end
    proc.exitcode == 0 && (proc.termsignal == 0 || proc.termsignal == SIGPIPE)
end

function success(x::Process)
    wait(x)
    kill(x)
    test_success(x)
end
success(procs::Vector{Process}) = mapreduce(success, &, procs)
success(procs::ProcessChain) = success(procs.processes)
success(cmd::AbstractCmd) = success(spawn(cmd))

function pipeline_error(proc::Process)
    if !proc.cmd.ignorestatus
        error("failed process: ", proc, " [", proc.exitcode, "]")
    end
    nothing
end

function pipeline_error(procs::ProcessChain)
    failed = Process[]
    for p = procs.processes
        if !test_success(p) && !p.cmd.ignorestatus
            push!(failed, p)
        end
    end
    length(failed) == 0 && return nothing
    length(failed) == 1 && pipeline_error(failed[1])
    msg = "failed processes:"
    for proc in failed
        msg = string(msg, "\n  ", proc, " [", proc.exitcode, "]")
    end
    error(msg)
end

_jl_kill(p::Process, signum::Integer) = ccall(:uv_process_kill, Int32, (Ptr{Void},Int32), p.handle, signum)
function kill(p::Process, signum::Integer)
    if process_running(p)
        @assert p.handle != C_NULL
        _jl_kill(p, signum)
    else
        Int32(-1)
    end
end
kill(ps::Vector{Process}) = map(kill, ps)
kill(ps::ProcessChain) = map(kill, ps.processes)
kill(p::Process) = kill(p, 15) #SIGTERM

function _contains_newline(bufptr::Ptr{Void}, len::Int32)
    return (ccall(:memchr, Ptr{Void}, (Ptr{Void},Int32,Csize_t), bufptr, '\n', len) != C_NULL)
end

## process status ##
process_running(s::Process) = s.exitcode == typemin(Int32)
process_running(s::Vector{Process}) = any(process_running, s)
process_running(s::ProcessChain) = process_running(s.processes)

process_exited(s::Process) = !process_running(s)
process_exited(s::Vector{Process}) = all(process_exited, s)
process_exited(s::ProcessChain) = process_exited(s.processes)

process_signaled(s::Process) = (s.termsignal > 0)

#process_stopped (s::Process) = false #not supported by libuv. Do we need this?
#process_stop_signal(s::Process) = false #not supported by libuv. Do we need this?

function process_status(s::Process)
    process_running(s) ? "ProcessRunning" :
    process_signaled(s) ? "ProcessSignaled("*string(s.termsignal)*")" :
    #process_stopped(s) ? "ProcessStopped("*string(process_stop_signal(s))*")" :
    process_exited(s) ? "ProcessExited("*string(s.exitcode)*")" :
    error("process status error")
end

## implementation of `cmd` syntax ##

arg_gen()          = ByteString[]
arg_gen(x::AbstractString) = ByteString[cstr(x)]
arg_gen(cmd::Cmd)  = cmd.exec

function arg_gen(head)
    if applicable(start, head)
        vals = ByteString[]
        for x in head
            push!(vals, cstr(string(x)))
        end
        return vals
    else
        return ByteString[cstr(string(head))]
    end
end

function arg_gen(head, tail...)
    head = arg_gen(head)
    tail = arg_gen(tail...)
    vals = ByteString[]
    for h = head, t = tail
        push!(vals, cstr(bytestring(h, t)))
    end
    vals
end

function cmd_gen(parsed)
    args = ByteString[]
    for arg in parsed
        append!(args, arg_gen(arg...))
    end
    Cmd(args)
end

macro cmd(str)
    :(cmd_gen($(shell_parse(str)[1])))
end

wait(x::Process)      = if !process_exited(x); stream_wait(x, x.exitnotify); end
wait(x::ProcessChain) = for p in x.processes; wait(p); end

show(io::IO, p::Process) = print(io, "Process(", p.cmd, ", ", process_status(p), ")")
