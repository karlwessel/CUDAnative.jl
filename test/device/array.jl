@testset "device arrays" begin

@testset "constructors" begin
    # inner constructors
    let
        p = Ptr{Int}(C_NULL)
        dp = CUDAnative.DevicePtr(p)
        CuDeviceArray{Int,1,AS.Generic}((1,), dp)
    end

    # outer constructors
    for I in [Int32,Int64]
        a = I(1)
        b = I(2)

        p = Ptr{I}(C_NULL)
        dp = CUDAnative.DevicePtr(p)

        # not parameterized
        CuDeviceArray(b, dp)
        CuDeviceArray((b,), dp)
        CuDeviceArray((b,a), dp)

        # partially parameterized
        CuDeviceArray{I}(b, dp)
        CuDeviceArray{I}((b,), dp)
        CuDeviceArray{I}((a,b), dp)
        CuDeviceArray{I,1}(b, dp)
        CuDeviceArray{I,1}((b,), dp)
        @test_throws MethodError CuDeviceArray{I,1}((a,b), dp)
        @test_throws MethodError CuDeviceArray{I,2}(b, dp)
        @test_throws MethodError CuDeviceArray{I,2}((b,), dp)
        CuDeviceArray{I,2}((a,b), dp)

        # fully parameterized
        CuDeviceArray{I,1,AS.Generic}(b, dp)
        CuDeviceArray{I,1,AS.Generic}((b,), dp)
        @test_throws MethodError CuDeviceArray{I,1,AS.Generic}((a,b), dp)
        @test_throws MethodError CuDeviceArray{I,1,AS.Shared}((a,b), dp)
        @test_throws MethodError CuDeviceArray{I,2,AS.Generic}(b, dp)
        @test_throws MethodError CuDeviceArray{I,2,AS.Generic}((b,), dp)
        CuDeviceArray{I,2,AS.Generic}((a,b), dp)

        # type aliases
        CuDeviceVector{I}(b, dp)
        CuDeviceMatrix{I}((a,b), dp)
    end
end

@testset "basics" begin     # argument passing, get and setindex, length
    dims = (16, 16)
    len = prod(dims)

    function kernel(input::CuDeviceArray{Float32}, output::CuDeviceArray{Float32})
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x

        if i <= length(input)
            output[i] = Float64(input[i])   # force conversion upon setindex!
        end

        return
    end

    input = round.(rand(Float32, dims) * 100)

    input_dev = CuTestArray(input)
    output_dev = CuTestArray(input)

    @cuda threads=len kernel(input_dev, output_dev)
    output = Array(output_dev)
    @test input ≈ output
end

@testset "iteration" begin     # argument passing, get and setindex, length
    dims = (16, 16)
    function kernel(input::CuDeviceArray{T}, output::CuDeviceArray{T}) where {T}
        acc = zero(T)
        for elem in input
            acc += elem
        end
        output[1] = acc
        return
    end

    input = round.(rand(Float32, dims) * 100)

    input_dev = CuTestArray(input)
    output_dev = CuTestArray(Float32[0])

    @cuda kernel(input_dev, output_dev)
    output = Array(output_dev)
    @test sum(input) ≈ output[1]
end

@testset "bounds checking" begin
    function oob_1d(array)
        return array[1]
    end

    ir = sprint(io->CUDAnative.code_llvm(io, oob_1d, (CuDeviceArray{Int,1,AS.Global},)))
    @test !occursin("julia_throw_boundserror", ir)
    @test occursin("ptx_throw_boundserror", ir)

    function oob_2d(array)
        return array[1, 1]
    end

    ir = sprint(io->CUDAnative.code_llvm(io, oob_2d, (CuDeviceArray{Int,2,AS.Global},)))
    @test !occursin("julia_throw_boundserror", ir)
    @test occursin("ptx_throw_boundserror", ir)
end

@testset "views" begin
    function kernel(array)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x

        _sub = view(array, 2:length(array)-1)
        if i <= length(_sub)
            _sub[i] = i
        end

        return
    end

    array = zeros(Int64, 100)
    array_dev = CuTestArray(array)

    sub = view(array, 2:length(array)-1)
    for i in 1:length(sub)
        sub[i] = i
    end

    @cuda threads=100 kernel(array_dev)
    @test array == Array(array_dev)
end

@testset "non-Int index to unsafe_load" begin
    function load_index(a)
        return a[UInt64(1)]
    end

    a = [1]
    p = pointer(a)
    dp = CUDAnative.DevicePtr(p)
    da = CUDAnative.CuDeviceArray(1, dp)
    load_index(da)
end

if capability(dev) >= v"3.2"
    @testset "ldg" begin
        function kernel(a, b, i)
            b[i] = ldg(a, i)
            return
        end

        buf = IOBuffer()

        a = CuTestArray([0])
        b = CuTestArray([0])
        @device_code_ptx io=buf @cuda kernel(a, b, 1)
        @test Array(a) == Array(b)

        asm = String(take!(copy(buf)))
        @test occursin("ld.global.nc", asm)
    end
end

end
