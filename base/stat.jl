# This file is a part of Julia. License is MIT: https://julialang.org/license

# filesystem operations

export
    ctime,
    filemode,
    filesize,
    gperm,
    isblockdev,
    ischardev,
    isdir,
    isfifo,
    isfile,
    islink,
    ismount,
    ispath,
    issetgid,
    issetuid,
    issocket,
    issticky,
    lstat,
    mtime,
    operm,
    stat,
    uperm

struct StatStruct
    desc    :: Union{String, OS_HANDLE} # for show method, not included in equality or hash
    device  :: UInt
    inode   :: UInt
    mode    :: UInt
    nlink   :: Int
    uid     :: UInt
    gid     :: UInt
    rdev    :: UInt
    size    :: Int64
    blksize :: Int64
    blocks  :: Int64
    mtime   :: Float64
    ctime   :: Float64
end

@eval function Base.:(==)(x::StatStruct, y::StatStruct) # do not include `desc` in equality or hash
  $(let ex = true
        for fld in fieldnames(StatStruct)[2:end]
            ex = :(getfield(x, $(QuoteNode(fld))) === getfield(y, $(QuoteNode(fld))) && $ex)
        end
        Expr(:return, ex)
    end)
end
@eval function Base.hash(obj::StatStruct, h::UInt)
  $(quote
        $(Any[:(h = hash(getfield(obj, $(QuoteNode(fld))), h)) for fld in fieldnames(StatStruct)[2:end]]...)
        return h
    end)
end

StatStruct() = StatStruct("", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
StatStruct(buf::Union{Vector{UInt8},Ptr{UInt8}}) = StatStruct("", buf)
StatStruct(desc::Union{AbstractString, OS_HANDLE}, buf::Union{Vector{UInt8},Ptr{UInt8}}) = StatStruct(
    desc isa OS_HANDLE ? desc : String(desc),
    ccall(:jl_stat_dev,     UInt32,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_ino,     UInt32,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_mode,    UInt32,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_nlink,   UInt32,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_uid,     UInt32,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_gid,     UInt32,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_rdev,    UInt32,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_size,    UInt64,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_blksize, UInt64,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_blocks,  UInt64,  (Ptr{UInt8},), buf),
    ccall(:jl_stat_mtime,   Float64, (Ptr{UInt8},), buf),
    ccall(:jl_stat_ctime,   Float64, (Ptr{UInt8},), buf),
)

function iso_datetime_with_relative(t, tnow)
    str = Libc.strftime("%FT%T%z", t)
    secdiff = t - tnow
    for (d, name) in ((24*60*60, "day"), (60*60, "hour"), (60, "minute"), (1, "second"))
        tdiff = round(Int, div(abs(secdiff), d))
        if tdiff != 0 # find first unit difference
            plural = tdiff == 1 ? "" : "s"
            when = secdiff < 0 ? "ago" : "in the future"
            return "$str ($tdiff $name$plural $when)"
        end
    end
    return "$str (just now)"
end


function getusername(uid::Unsigned)
    pwd = Libc.getpwuid(uid, false)
    pwd === nothing && return
    isempty(pwd.username) && return
    return pwd.username
end

function getgroupname(gid::Unsigned)
    gp = Libc.getgrgid(gid, false)
    gp === nothing && return
    isempty(gp.groupname) && return
    return gp.groupname
end

function show_statstruct(io::IO, st::StatStruct, oneline::Bool)
    print(io, oneline ? "StatStruct(" : "StatStruct for ")
    show(io, st.desc)
    oneline || print(io, "\n  ")
    print(io, " size: ", st.size, " bytes")
    oneline || print(io, "\n")
    print(io, " device: ", st.device)
    oneline || print(io, "\n ")
    print(io, " inode: ", st.inode)
    oneline || print(io, "\n  ")
    print(io, " mode: 0o", string(filemode(st), base = 8, pad = 6), " (", filemode_string(st), ")")
    oneline || print(io, "\n ")
    print(io, " nlink: ", st.nlink)
    oneline || print(io, "\n   ")
    print(io, " uid: $(st.uid)")
    username = getusername(st.uid)
    username === nothing || print(io, " (", username, ")")
    oneline || print(io, "\n   ")
    print(io, " gid: ", st.gid)
    groupname = getgroupname(st.gid)
    groupname === nothing || print(io, " (", groupname, ")")
    oneline || print(io, "\n  ")
    print(io, " rdev: ", st.rdev)
    oneline || print(io, "\n ")
    print(io, " blksz: ", st.blksize)
    oneline || print(io, "\n")
    print(io, " blocks: ", st.blocks)
    tnow = round(UInt, time())
    oneline || print(io, "\n ")
    print(io, " mtime: ", iso_datetime_with_relative(st.mtime, tnow))
    oneline || print(io, "\n ")
    print(io, " ctime: ", iso_datetime_with_relative(st.ctime, tnow))
    oneline && print(io, ")")
    return nothing
end

show(io::IO, st::StatStruct) = show_statstruct(io, st, true)
show(io::IO, ::MIME"text/plain", st::StatStruct) = show_statstruct(io, st, false)

# stat & lstat functions

macro stat_call(sym, arg1type, arg)
    return quote
        stat_buf = zeros(UInt8, Int(ccall(:jl_sizeof_stat, Int32, ())))
        r = ccall($(Expr(:quote, sym)), Int32, ($(esc(arg1type)), Ptr{UInt8}), $(esc(arg)), stat_buf)
        if !(r in (0, Base.UV_ENOENT, Base.UV_ENOTDIR, Base.UV_EINVAL))
            uv_error(string("stat(", repr($(esc(arg))), ")"), r)
        end
        st = StatStruct($(esc(arg)), stat_buf)
        if ispath(st) != (r == 0)
            error("stat returned zero type for a valid path")
        end
        return st
    end
end

stat(fd::OS_HANDLE)         = @stat_call jl_fstat OS_HANDLE fd
stat(path::AbstractString)  = @stat_call jl_stat  Cstring path
lstat(path::AbstractString) = @stat_call jl_lstat Cstring path
if RawFD !== OS_HANDLE
    global stat(fd::RawFD)  = stat(Libc._get_osfhandle(fd))
end
stat(fd::Integer)           = stat(RawFD(fd))

"""
    stat(file)

Returns a structure whose fields contain information about the file.
The fields of the structure are:

| Name    | Description                                                        |
|:--------|:-------------------------------------------------------------------|
| desc    | The path or OS file descriptor                                     |
| size    | The size (in bytes) of the file                                    |
| device  | ID of the device that contains the file                            |
| inode   | The inode number of the file                                       |
| mode    | The protection mode of the file                                    |
| nlink   | The number of hard links to the file                               |
| uid     | The user id of the owner of the file                               |
| gid     | The group id of the file owner                                     |
| rdev    | If this file refers to a device, the ID of the device it refers to |
| blksize | The file-system preferred block size for the file                  |
| blocks  | The number of such blocks allocated                                |
| mtime   | Unix timestamp of when the file was last modified                  |
| ctime   | Unix timestamp of when the file's metadata was changed             |

"""
stat(path...) = stat(joinpath(path...))

"""
    lstat(file)

Like [`stat`](@ref), but for symbolic links gets the info for the link
itself rather than the file it refers to.
This function must be called on a file path rather than a file object or a file
descriptor.
"""
lstat(path...) = lstat(joinpath(path...))

# some convenience functions

const filemode_table = (
    [
        (S_IFLNK, "l"),
        (S_IFSOCK, "s"),  # Must appear before IFREG and IFDIR as IFSOCK == IFREG | IFDIR
        (S_IFREG, "-"),
        (S_IFBLK, "b"),
        (S_IFDIR, "d"),
        (S_IFCHR, "c"),
        (S_IFIFO, "p")
    ],
    [
        (S_IRUSR, "r"),
    ],
    [
        (S_IWUSR, "w"),
    ],
    [
        (S_IXUSR|S_ISUID, "s"),
        (S_ISUID, "S"),
        (S_IXUSR, "x")
    ],
    [
        (S_IRGRP, "r"),
    ],
    [
        (S_IWGRP, "w"),
    ],
    [
        (S_IXGRP|S_ISGID, "s"),
        (S_ISGID, "S"),
        (S_IXGRP, "x")
    ],
    [
        (S_IROTH, "r"),
    ],
    [
        (S_IWOTH, "w"),
    ],
    [
        (S_IXOTH|S_ISVTX, "t"),
        (S_ISVTX, "T"),
        (S_IXOTH, "x")
    ]
)

"""
    filemode(file)

Equivalent to `stat(file).mode`.
"""
filemode(st::StatStruct) = st.mode
filemode_string(st::StatStruct) = filemode_string(st.mode)
function filemode_string(mode)
    str = IOBuffer()
    for table in filemode_table
        complete = true
        for (bit, char) in table
            if mode & bit == bit
                write(str, char)
                complete = false
                break
            end
        end
        complete && write(str, "-")
    end
    return String(take!(str))
end

"""
    filesize(path...)

Equivalent to `stat(file).size`.
"""
filesize(st::StatStruct) = st.size

"""
    mtime(file)

Equivalent to `stat(file).mtime`.
"""
mtime(st::StatStruct) = st.mtime

"""
    ctime(file)

Equivalent to `stat(file).ctime`.
"""
ctime(st::StatStruct) = st.ctime

# mode type predicates

"""
    ispath(path) -> Bool

Return `true` if a valid filesystem entity exists at `path`,
otherwise returns `false`.
This is the generalization of [`isfile`](@ref), [`isdir`](@ref) etc.
"""
ispath(st::StatStruct) = filemode(st) & 0xf000 != 0x0000

"""
    isfifo(path) -> Bool

Return `true` if `path` is a FIFO, `false` otherwise.
"""
isfifo(st::StatStruct) = filemode(st) & 0xf000 == 0x1000

"""
    ischardev(path) -> Bool

Return `true` if `path` is a character device, `false` otherwise.
"""
ischardev(st::StatStruct) = filemode(st) & 0xf000 == 0x2000

"""
    isdir(path) -> Bool

Return `true` if `path` is a directory, `false` otherwise.

# Examples
```jldoctest
julia> isdir(homedir())
true

julia> isdir("not/a/directory")
false
```

See also [`isfile`](@ref) and [`ispath`](@ref).
"""
isdir(st::StatStruct) = filemode(st) & 0xf000 == 0x4000

"""
    isblockdev(path) -> Bool

Return `true` if `path` is a block device, `false` otherwise.
"""
isblockdev(st::StatStruct) = filemode(st) & 0xf000 == 0x6000

"""
    isfile(path) -> Bool

Return `true` if `path` is a regular file, `false` otherwise.

# Examples
```jldoctest
julia> isfile(homedir())
false

julia> filename = "test_file.txt";

julia> write(filename, "Hello world!");

julia> isfile(filename)
true

julia> rm(filename);

julia> isfile(filename)
false
```

See also [`isdir`](@ref) and [`ispath`](@ref).
"""
isfile(st::StatStruct) = filemode(st) & 0xf000 == 0x8000

"""
    islink(path) -> Bool

Return `true` if `path` is a symbolic link, `false` otherwise.
"""
islink(st::StatStruct) = filemode(st) & 0xf000 == 0xa000

"""
    issocket(path) -> Bool

Return `true` if `path` is a socket, `false` otherwise.
"""
issocket(st::StatStruct) = filemode(st) & 0xf000 == 0xc000

# mode permission predicates

"""
    issetuid(path) -> Bool

Return `true` if `path` has the setuid flag set, `false` otherwise.
"""
issetuid(st::StatStruct) = (filemode(st) & 0o4000) > 0

"""
    issetgid(path) -> Bool

Return `true` if `path` has the setgid flag set, `false` otherwise.
"""
issetgid(st::StatStruct) = (filemode(st) & 0o2000) > 0

"""
    issticky(path) -> Bool

Return `true` if `path` has the sticky bit set, `false` otherwise.
"""
issticky(st::StatStruct) = (filemode(st) & 0o1000) > 0

"""
    uperm(file)

Get the permissions of the owner of the file as a bitfield of

| Value | Description        |
|:------|:-------------------|
| 01    | Execute Permission |
| 02    | Write Permission   |
| 04    | Read Permission    |

For allowed arguments, see [`stat`](@ref).
"""
uperm(st::StatStruct) = UInt8((filemode(st) >> 6) & 0x7)

"""
    gperm(file)

Like [`uperm`](@ref) but gets the permissions of the group owning the file.
"""
gperm(st::StatStruct) = UInt8((filemode(st) >> 3) & 0x7)

"""
    operm(file)

Like [`uperm`](@ref) but gets the permissions for people who neither own the file nor are a member of
the group owning the file
"""
operm(st::StatStruct) = UInt8((filemode(st)     ) & 0x7)

# mode predicate methods for file names

for f in Symbol[
    :ispath,
    :isfifo,
    :ischardev,
    :isdir,
    :isblockdev,
    :isfile,
    :issocket,
    :issetuid,
    :issetgid,
    :issticky,
    :uperm,
    :gperm,
    :operm,
    :filemode,
    :filesize,
    :mtime,
    :ctime,
]
    @eval ($f)(path...)  = ($f)(stat(path...))
end

islink(path...) = islink(lstat(path...))

# samefile can be used for files and directories: #11145#issuecomment-99511194
samefile(a::StatStruct, b::StatStruct) = a.device==b.device && a.inode==b.inode

"""
    samefile(path_a::AbstractString, path_b::AbstractString)

Check if the paths `path_a` and `path_b` refer to the same existing file or directory.
"""
function samefile(a::AbstractString, b::AbstractString)
    infoa = stat(a)
    infob = stat(b)
    if ispath(infoa) && ispath(infob)
        samefile(infoa, infob)
    else
        return false
    end
end

"""
    ismount(path) -> Bool

Return `true` if `path` is a mount point, `false` otherwise.
"""
function ismount(path...)
    path = joinpath(path...)
    isdir(path) || return false
    s1 = lstat(path)
    # Symbolic links cannot be mount points
    islink(s1) && return false
    parent_path = joinpath(path, "..")
    s2 = lstat(parent_path)
    # If a directory and its parent are on different devices,  then the
    # directory must be a mount point
    (s1.device != s2.device) && return true
    (s1.inode == s2.inode) && return true
    false
end
