module RomeoDBFixture
export coordinate_grid

"""Build coordinate matrices from two coordinate vectors."""
function coordinate_grid(xs, ys)
    nx, ny = length(xs), length(ys)
    x = reshape(xs, 1, nx)
    y = reshape(ys, ny, 1)
    return repeat(x, ny, 1), repeat(y, 1, nx)
end
end
