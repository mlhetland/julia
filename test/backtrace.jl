# This file is a part of Julia. License is MIT: http://julialang.org/license

bt = backtrace()
have_backtrace = false
for l in bt
    lkup = ccall(:jl_lookup_code_address, Any, (Ptr{Void},), l)
    if lkup[1] == :backtrace
        @test lkup[6] == false # fromC
        have_backtrace = true
        break
    end
end

@test have_backtrace
