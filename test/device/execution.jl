@testset "execution" begin

############################################################################################

dummy() = return

@testset "cufunction" begin
    @test_throws UndefVarError cufunction(exec_undefined_kernel, ())

    cufunction(dev, dummy, Tuple{})

    # NOTE: other cases are going to be covered by tests below,
    #       as @cuda internally uses cufunction
end

############################################################################################


@testset "@cuda" begin

@test_throws UndefVarError @cuda undefined()
@test_throws MethodError @cuda dummy(1)


@testset "compilation params" begin
    @cuda dummy()

    @test_throws CuError @cuda threads=2 maxthreads=1 dummy()
    @cuda threads=2 dummy()
end


@testset "reflection" begin
    CUDAnative.code_lowered(dummy, Tuple{})
    CUDAnative.code_typed(dummy, Tuple{})
    CUDAnative.code_warntype(devnull, dummy, Tuple{})
    CUDAnative.code_llvm(devnull, dummy, Tuple{})
    CUDAnative.code_ptx(devnull, dummy, Tuple{})
    CUDAnative.code_sass(devnull, dummy, Tuple{})

    @device_code_lowered @cuda dummy()
    @device_code_typed @cuda dummy()
    @device_code_warntype io=devnull @cuda dummy()
    @device_code_llvm io=devnull @cuda dummy()
    @device_code_ptx io=devnull @cuda dummy()
    @device_code_sass io=devnull @cuda dummy()

    mktempdir() do dir
        @device_code dir=dir @cuda dummy()
    end

    @test_throws ErrorException @device_code_lowered nothing

    # make sure kernel name aliases are preserved in the generated code
    @test occursin("ptxcall_dummy", sprint(io->(@device_code_llvm io=io @cuda dummy())))
    @test occursin("ptxcall_dummy", sprint(io->(@device_code_ptx io=io @cuda dummy())))
    @test occursin("ptxcall_dummy", sprint(io->(@device_code_sass io=io @cuda dummy())))
end


@testset "shared memory" begin
    @cuda shmem=1 dummy()
end


@testset "streams" begin
    s = CuStream()
    @cuda stream=s dummy()
end


@testset "external kernels" begin
    @eval module KernelModule
        export external_dummy
        external_dummy() = return
    end
    import ...KernelModule
    @cuda KernelModule.external_dummy()
    @eval begin
        using ...KernelModule
        @cuda external_dummy()
    end

    @eval module WrapperModule
        using CUDAnative
        @eval dummy() = return
        wrapper() = @cuda dummy()
    end
    WrapperModule.wrapper()
end


@testset "calling device function" begin
    @noinline child(i) = sink(i)
    function parent()
        child(1)
        return
    end

    @cuda parent()
end

end


############################################################################################

@testset "argument passing" begin

dims = (16, 16)
len = prod(dims)

@testset "manually allocated" begin
    function kernel(input, output)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x

        val = unsafe_load(input, i)
        unsafe_store!(output, val, i)

        return
    end

    input = round.(rand(Float32, dims) * 100)
    output = similar(input)

    input_dev = Mem.upload(input)
    output_dev = Mem.alloc(input)

    @cuda threads=len kernel(Base.unsafe_convert(Ptr{Float32}, input_dev),
                             Base.unsafe_convert(Ptr{Float32}, output_dev))
    Mem.download!(output, output_dev)
    @test input ≈ output
end


@testset "scalar through single-value array" begin
    function kernel(a, x)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x
        max = gridDim().x * blockDim().x
        if i == max
            _val = unsafe_load(a, i)
            unsafe_store!(x, _val)
        end
        return
    end

    arr = round.(rand(Float32, dims) * 100)
    val = [0f0]

    arr_dev = Mem.upload(arr)
    val_dev = Mem.upload(val)

    @cuda threads=len kernel(Base.unsafe_convert(Ptr{Float32}, arr_dev),
                             Base.unsafe_convert(Ptr{Float32}, val_dev))
    @test arr[dims...] ≈ Mem.download(eltype(val), val_dev)[1]
end


@testset "scalar through single-value array, using device function" begin
    function child(a, i)
        return unsafe_load(a, i)
    end
    @noinline function parent(a, x)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x
        max = gridDim().x * blockDim().x
        if i == max
            _val = child(a, i)
            unsafe_store!(x, _val)
        end
        return
    end

    arr = round.(rand(Float32, dims) * 100)
    val = [0f0]

    arr_dev = Mem.upload(arr)
    val_dev = Mem.upload(val)

    @cuda threads=len parent(Base.unsafe_convert(Ptr{Float32}, arr_dev),
                             Base.unsafe_convert(Ptr{Float32}, val_dev))
    @test arr[dims...] ≈ Mem.download(eltype(val), val_dev)[1]
end


@testset "tuples" begin
    # issue #7: tuples not passed by pointer

    function kernel(keeps, out)
        if keeps[1]
            unsafe_store!(out, 1)
        else
            unsafe_store!(out, 2)
        end
        return
    end

    keeps = (true,)
    d_out = Mem.alloc(Int)

    @cuda kernel(keeps, Base.unsafe_convert(Ptr{Int}, d_out))
    @test Mem.download(Int, d_out) == [1]
end


@testset "ghost function parameters" begin
    # bug: ghost type function parameters are elided by the compiler

    len = 60
    a = rand(Float32, len)
    b = rand(Float32, len)
    c = similar(a)

    d_a = Mem.upload(a)
    d_b = Mem.upload(b)
    d_c = Mem.alloc(c)

    @eval struct ExecGhost end

    function kernel(ghost, a, b, c)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x
        unsafe_store!(c, unsafe_load(a,i)+unsafe_load(b,i), i)
        return
    end
    @cuda threads=len kernel(ExecGhost(),
                             Base.unsafe_convert(Ptr{Float32}, d_a),
                             Base.unsafe_convert(Ptr{Float32}, d_b),
                             Base.unsafe_convert(Ptr{Float32}, d_c))
    Mem.download!(c, d_c)
    @test a+b == c


    # bug: ghost type function parameters confused aggregate type rewriting

    function kernel(ghost, out, aggregate)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x
        unsafe_store!(out, aggregate[1], i)
        return
    end
    @cuda threads=len kernel(ExecGhost(), Base.unsafe_convert(Ptr{Float32}, d_c), (42,))

    Mem.download!(c, d_c)
    @test all(val->val==42, c)
end


@testset "immutables" begin
    # issue #15: immutables not passed by pointer

    function kernel(ptr, b)
        unsafe_store!(ptr, imag(b))
        return
    end

    buf = Mem.upload([0f0])
    x = ComplexF32(2,2)

    @cuda kernel(Base.unsafe_convert(Ptr{Float32}, buf), x)
    @test Mem.download(Float32, buf) == [imag(x)]
end


@testset "automatic recompilation" begin
    buf = Mem.alloc(Int)

    function kernel(ptr)
        unsafe_store!(ptr, 1)
        return
    end

    @cuda kernel(Base.unsafe_convert(Ptr{Int}, buf))
    @test Mem.download(Int, buf) == [1]

    function kernel(ptr)
        unsafe_store!(ptr, 2)
        return
    end

    @cuda kernel(Base.unsafe_convert(Ptr{Int}, buf))
    @test Mem.download(Int, buf) == [2]
end


@testset "non-isbits arguments" begin
    function kernel1(T, i)
        sink(i)
        return
    end
    @cuda kernel1(Int, 1)

    function kernel2(T, i)
        sink(unsafe_trunc(T,i))
        return
    end
    @cuda kernel2(Int, 1.)
end


@testset "splatting" begin
    function kernel(out, a, b)
        unsafe_store!(out, a+b)
        return
    end

    out = [0]
    out_dev = Mem.upload(out)
    out_ptr = Base.unsafe_convert(Ptr{eltype(out)}, out_dev)

    @cuda kernel(out_ptr, 1, 2)
    @test Mem.download(eltype(out), out_dev)[1] == 3

    all_splat = (out_ptr, 3, 4)
    @cuda kernel(all_splat...)
    @test Mem.download(eltype(out), out_dev)[1] == 7

    partial_splat = (5, 6)
    @cuda kernel(out_ptr, partial_splat...)
    @test Mem.download(eltype(out), out_dev)[1] == 11
end

@testset "object invoke" begin
    # this mimics what is generated by closure conversion

    @eval struct KernelObject{T} <: Function
        val::T
    end

    function (self::KernelObject)(a)
        unsafe_store!(a, self.val)
        return
    end

    function outer(a, val)
       inner = KernelObject(val)
       @cuda inner(a)
    end

    a = [1.]
    a_dev = Mem.upload(a)

    outer(Base.unsafe_convert(Ptr{Float64}, a_dev), 2.)

    @test Mem.download(eltype(a), a_dev) ≈ [2.]
end

@testset "closures" begin
    function outer(a_dev, val)
       function inner(a)
            # captures `val`
            unsafe_store!(a, val)
            return
       end
       @cuda inner(Base.unsafe_convert(Ptr{Float64}, a_dev))
    end

    a = [1.]
    a_dev = Mem.upload(a)

    outer(a_dev, 2.)

    @test Mem.download(eltype(a), a_dev) ≈ [2.]
end

@testset "conversions" begin
    @eval struct Host   end
    @eval struct Device end

    CUDAnative.cudaconvert(a::Host) = Device()

    Base.convert(::Type{Int}, ::Host)   = 1
    Base.convert(::Type{Int}, ::Device) = 2

    out = [0]

    # convert arguments
    out_dev = Mem.upload(out)
    let arg = Host()
        @test Mem.download(eltype(out), out_dev) ≈ [0]
        function kernel(arg, out)
            unsafe_store!(out, convert(Int, arg))
            return
        end
        @cuda kernel(arg, Base.unsafe_convert(Ptr{Int}, out_dev))
        @test Mem.download(eltype(out), out_dev) ≈ [2]
    end

    # convert tuples
    out_dev = Mem.upload(out)
    let arg = (Host(),)
        @test Mem.download(eltype(out), out_dev) ≈ [0]
        function kernel(arg, out)
            unsafe_store!(out, convert(Int, arg[1]))
            return
        end
        @cuda kernel(arg, Base.unsafe_convert(Ptr{Int}, out_dev))
        @test Mem.download(eltype(out), out_dev) ≈ [2]
    end

    # convert named tuples
    out_dev = Mem.upload(out)
    let arg = (a=Host(),)
        @test Mem.download(eltype(out), out_dev) ≈ [0]
        function kernel(arg, out)
            unsafe_store!(out, convert(Int, arg.a))
            return
        end
        @cuda kernel(arg, Base.unsafe_convert(Ptr{Int}, out_dev))
        @test Mem.download(eltype(out), out_dev) ≈ [2]
    end

    # don't convert structs
    out_dev = Mem.upload(out)
    @eval struct Nested
        a::Host
    end
    let arg = Nested(Host())
        @test Mem.download(eltype(out), out_dev) ≈ [0]
        function kernel(arg, out)
            unsafe_store!(out, convert(Int, arg.a))
            return
        end
        @cuda kernel(arg, Base.unsafe_convert(Ptr{Int}, out_dev))
        @test Mem.download(eltype(out), out_dev) ≈ [1]
    end
end

@testset "argument count" begin
    val = [0]
    val_dev = Mem.upload(val)
    ptr = Base.unsafe_convert(Ptr{Int}, val_dev)
    for i in (1, 10, 20, 35)
        variables = ('a':'z'..., 'A':'Z'...)
        params = [Symbol(variables[j]) for j in 1:i]
        # generate a kernel
        body = quote
            function kernel($(params...))
                unsafe_store!($ptr, $(Expr(:call, :+, params...)))
                return
            end
        end
        eval(body)
        args = [j for j in 1:i]
        call = Expr(:call, :kernel, args...)
        cudacall = :(@cuda $call)
        eval(cudacall)
        @test Mem.download(eltype(val), val_dev)[1] == sum(args)
    end
end

end

############################################################################################

end
