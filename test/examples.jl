@testset "examples" begin

function find_sources(path::String, sources=String[])
    if isdir(path)
        for entry in readdir(path)
            find_sources(joinpath(path, entry), sources)
        end
    elseif endswith(path, ".jl")
        push!(sources, path)
    end
    sources
end

examples_dir = joinpath(@__DIR__, "..", "examples")
examples = find_sources(examples_dir)
filter!(file -> readline(file) != "# EXCLUDE FROM TESTING", examples)

is_shared_memory_supported = all(CUDAdrv.attribute(dev, CUDAdrv.MANAGED_MEMORY) .== 1 
        for dev in CUDAdrv.devices())
filter!(file -> is_shared_memory_supported || basename(file) != "multigpu.jl", examples)

cd(examples_dir) do
    examples = relpath.(examples, Ref(examples_dir))
    @testset for example in examples
        cmd = julia_cmd(`$example`)
        @test success(pipeline(cmd, stderr=stderr))
    end
end

end
