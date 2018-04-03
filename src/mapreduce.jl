
using Base.Threads

export maptosites!, maptosites_d!

const MAX_THREADS = 1_000_000
function set_maxthreads!(n)
   NeighbourLists.MAX_THREADS = n
end

function mt_split(niter::TI, maxthreads=MAX_THREADS) where TI
   nt = minimum([maxthreads, nthreads(), niter])
   nn = ceil.(TI, linspace(1, niter+1, nt+1))
   rgs = [nn[i]:(nn[i+1]-1) for i = 1:nt]
   return nt, rgs
end

function mt_split_interlaced(niter::TI, maxthreads=MAX_THREADS) where TI
   nt = minimum([maxthreads, nthreads(), niter])
   rgs = [ j:nt:niter for j = 1:nt ]
   return nt, rgs
end


function _mt_map_!(f::FT, out, it, inner_loop) where FT
   nt, rg = mt_split_interlaced(length(it))
   if nt == 1
      inner_loop(f, out, it, 1:length(it))
   else
      out_i = [ zeros(eltype(out), length(out)) for i=1:nt]
      @threads for i = 1:nt
         inner_loop(f, out_i[i], it, rg[i])
      end
      for i = 1:nt
         out .+= out_i[i]
      end
   end
   return out
end

maptosites!(f, out::AbstractVector, it::AbstractIterator) =
   _mt_map_!(f, out, it, maptosites_inner!)

maptosites_d!(f, out::AbstractVector, it::AbstractIterator) =
   _mt_map_!(f, out, it, maptosites_d_inner!)

# ============ assembly over pairs


"""
`mapreduce_sym!{S, T}(out::AbstractVector{S}, f, it::PairIterator{T})`

symmetric variant of `mapreduce!{S, T}(out::AbstractVector{S}, ...)`, summing only
over bonds (i,j) with i < j and adding f(R_ij) to both sites i, j.
"""
function maptosites_inner!(f::FT, out, it::PairIterator, rg) where FT
   nlist = it.nlist
   for n in rg
      if  nlist.i[n] < nlist.j[n]
         f_ = f(nlist.r[n], nlist.R[n]) / 2
         out[nlist.i[n]] += f_
         out[nlist.j[n]] += f_
      end
   end
   return out
end


"""
`mapreduce_antisym!{T}(out::AbstractVector{SVec{T}}, df, it::PairIterator{T})`

anti-symmetric variant of `mapreduce!{S, T}(out::AbstractVector{S}, ...)`, summing only
over bonds (i,j) with i < j and adding f(R_ij) to site j and
-f(R_ij) to site i.
"""
function maptosites_d_inner!(f::FT, out, it::PairIterator, rg) where FT
   nlist = it.nlist
   for n in rg
      if nlist.i[n] < nlist.j[n]
         f_ = f(nlist.r[n], nlist.R[n])
         out[nlist.j[n]] += f_
         out[nlist.i[n]] -= f_
      end
   end
   return out
end


# ============ assembly over sites

function maptosites_inner!(f::FT, out, it::SiteIterator, rg) where FT
   for i in rg
      j, r, R = site(it.nlist, i)
      out[i] = f(r, R)
   end
   return out
end

function maptosites_d_inner!(df::FT, out, it::SiteIterator, rg) where FT
   for i in rg
      j, r, R = site(it.nlist, i)
      df_ = df(r, R)
      out[j] += df_
      out[i] -= sum(df_)
   end
   return out
end



# ============ assembly over n-body terms

"""
`@symm`: symmetrises a loop over a cartesian range. For example
```Julia
for i1 = a0:a1-2, i2 = i1+1:a1-1, i3 = i2+1:a1
   dosomething(i1, i2, i3)
end
```
may be written as
```Julia
@symm 3 for i = a0:a1
   dosomething(i[1], i[2], i[3])
end
```
here, `i` is a `CartesianIndex`.
"""
macro symm(N, ex)
   if N isa Symbol
      N = eval(N)
   end
   @assert ex.head == :for
   @assert length(ex.args) == 2
   ex_for = ex.args[1]
   ex_body = ex.args[2]
   # iteration symbol
   i = ex_for.args[1]
   # lower and upper bound
   a0 = ex_for.args[2].args[1]
   a1 = ex_for.args[2].args[2]
   # create the for-loop without body, e.g., for a 3-body assembly it generates
   #   for i1 = a0:a1-2, i2 = i1+1:a1-1, i3 = i2+1:a1
   #      do something with (i1, i2, i3)
   #   end
   loopstr = "for $(i)1 = ($a0):(($a1)-$(N-1))"
   for n = 2:N
      loopstr *= ", $i$n = $i$(n-1)+1:(($a1)-$(N-n))"
   end
   loopstr *= "\n $i = SVector{$N, Int}($(i)1"
   for n = 2:N
      loopstr *= ", $i$n"
   end
   loopstr *= ") \n end"
   loopex = parse(loopstr)
   append!(loopex.args[2].args, ex_body.args)
   # return the expression
   esc(quote
      $loopex
   end)
end




"""
`function _find_next_(j, n, first)`

* `j` : array of neighbour indices
* `n` : current site index
* `first` : array of first indices

return the first index `first[n] <= m < first[n+1]` such that `j[m] > n`;
and returns 0 if no such index exists
"""
function _find_next_(j::Vector{TI}, n::TI, first::Vector{TI}) where TI
   # DEBUG CODE
   # @assert issorted(j[first[n]:first[n+1]-1])
   for m = first[n]:first[n+1]-1
      if j[m] > n
         return m
      end
   end
   return zero(TI)
end

"""
`simplex_lengths`: compute the sidelengths of a simplex
and return the corresponding pairs of X indices
"""
function simplex_lengths!(s, a, b, i, J::SVector{N, TI}, nlist
                           ) where {N, TI <: Integer}
   n = 0
   for l = 1:N
      n += 1
      a[n] = i
      b[n] = nlist.j[J[l]]
      s[n] = nlist.r[J[l]]
   end
   for i1 = 1:N-1, j1 = i1+1:N
      n += 1
      a[n] = nlist.j[J[i1]]
      b[n] = nlist.j[J[j1]]
      s[n] = norm(nlist.R[J[i1]] - nlist.R[J[j1]])
   end
   return SVector(s), SVector(a), SVector(b)
end


@generated function maptosites_inner!(f::FT, out::AbstractVector,
                        it::NBodyIterator{N, T, TI}, rg) where {FT, N, T, TI}
   N2 = (N*(N-1))÷2
   quote
      nlist = it.nlist
      # allocate some temporary arrays
      a_ = zero(MVector{$N2, TI})
      b_ = zero(MVector{$N2, TI})
      s_ = zero(MVector{$N2, T})
      # loop over the range allocated to this thread
      for i in rg
         # get the index of a neighbour > n
         a0 = _find_next_(nlist.j, i, nlist.first)
         a0 == 0 && continue  # (if no such index exists)
         # get the index up to which to loop
         a1 = nlist.first[i+1]-1
         @symm $(N-1) for J = a0:a1
            # compute the N(N+1)/2 vector of distances
            s, _, _ = simplex_lengths!(s_, a_, b_, i, J, nlist)
         #                        ~~~~~~~~~~~~~~~~~~~ generic up to here
            f_ = f(s) / $N
            out[i] += f_
            for l = 1:length(J)
               out[nlist.j[J[l]]] += f_
            end
         end
      end
   end
end



@generated function maptosites_d_inner!(df::FT, out::AbstractVector,
                        it::NBodyIterator{N, T, TI}, rg) where {FT, N, T, TI}
   N2 = (N*(N-1))÷2
   quote
      nlist = it.nlist
      # allocate some temporary arrays
      a_ = zero(MVector{$N2, TI})
      b_ = zero(MVector{$N2, TI})
      s_ = zero(MVector{$N2, T})
      # loop over the range allocated to this thread
      for i in rg
         # get the index of a neighbour > n
         a0 = _find_next_(nlist.j, i, nlist.first)
         a0 == 0 && continue  # (if no such index exists)
         # get the index up to which to loop
         a1 = nlist.first[i+1]-1
         @symm $(N-1) for J = a0:a1
            # compute the N(N+1)/2 vector of distances
            s, a, b = simplex_lengths!(s_, a_, b_, i, J, nlist)
         #                        ~~~~~~~~~~~~~~~~~~~ generic up to here
            df_ = df(s)
            for l = 1:length(s)
               Rab = nlist.X[a[l]] - nlist.X[b[l]]
               Sab = Rab / norm(Rab)
               out[a[l]] += df_[l] * Sab
               out[b[l]] -= df_[l] * Sab
            end
         end
      end
   end
end
