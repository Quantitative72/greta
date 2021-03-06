#' @name extract-replace-combine
#' @aliases extract replace cbind rbind c rep
#' @title extract, replace and combine greta arrays
#'
#' @description Generic methods to extract and replace elements of greta arrays,
#'   or to combine greta arrays.
#'
#' @section Usage: \preformatted{
#' # extract
#' x[i]
#' x[i, j, ..., drop = FALSE]
#' head(x, n = 6L, ...)
#' tail(x, n = 6L, ...)
#'
#' # replace
#' x[i] <- value
#' x[i, j, ...] <- value
#'
#' # combine
#' cbind(...)
#' rbind(...)
#' c(..., recursive = FALSE)
#' rep(x, times, ..., recursive = FALSE)
#'
#' # get and set dimensions
#' length(x)
#' dim(x)
#' dim(x) <- value
#' }
#'
#' @param x a greta array
#' @param i,j indices specifying elements to extract or replace
#' @param n a single integer, as in \code{utils::head()} and
#'   \code{utils::tail()}
#' @param value for \code{`[<-`} a greta array to replace elements, for
#'   \code{`dim<-`} either NULL or a numeric vector of dimensions
#' @param ... either further indices specifying elements to extract or replace
#'   (\code{[}), or multiple greta arrays to combine (\code{cbind()},
#'   \code{rbind()} & \code{c()}), or additional arguments (\code{rep()},
#'   \code{head()}, \code{tail()})
#' @param drop,recursive generic arguments that are ignored for greta arrays
#'
#' @examples
#' \dontrun{
#'
#'  x = as_data(matrix(1:12, 3, 4))
#'
#'  # extract/replace
#'  x[1:3, ]
#'  x[, 2:4] <- 1:9
#'
#'  # combine
#'  cbind(x[, 2], x[, 1])
#'  rbind(x[1, ], x[3, ])
#'  c(x[, 1], x)
#'  rep(x[, 2], times = 3)
#' }
NULL

# extract syntax for greta_array objects
#' @export
`[.greta_array` <- function(x, ...) {

  # store the full call to mimic on a dummy array, plus the array's dimensions
  call <- sys.call()
  dims_in <- dim(x)

  # create a dummy array containing the order of elements Python-style
  dummy_in <- dummy(dims_in)

  # modify the call, switching to primitive subsetting, changing the target
  # object, and ensuring no dropping happens
  call_list <- as.list(call)[-1]
  call_list[[1]] <- as.name("._dummy_in")
  call_list$drop <- FALSE

  # put dummy_in in the parent environment & execute there (to evaluate any
  # promises using variables in that environment), then remove
  pf <- parent.frame()
  assign('._dummy_in', dummy_in, envir = pf)
  dummy_out <- do.call(.Primitive("["), call_list, envir = pf)
  rm('._dummy_in', envir = pf)

  # if this is a data node, also subset the values and pass on
  if (inherits(x$node, 'data_node')) {

    values_in <- x$node$value()
    call_list <- as.list(call)[-1]
    call_list[[1]] <- as.name("._values_in")
    call_list$drop <- FALSE

    # put values_in in the parent environment & execute there (to evaluate any
    # promises using variables in that environment), then remove
    pf <- parent.frame()
    assign('._values_in', values_in, envir = pf)
    values_out <- do.call(.Primitive("["), call_list, envir = pf)
    rm('._values_in', envir = pf)

    # make sure it's an array
    values <- as.array(values_out)

  } else {

    values <- NULL

  }

  # coerce result to an array
  dummy_out <- as.array(dummy_out)

  # get number of elements in input and dimension of output
  nelem <- prod(dims_in)
  dims_out <- dim(dummy_out)

  # make sure it's a column vector
  if (length(dims_out) == 1)
    dims_out <- c(dims_out, 1)

  # give values these dimensions
  if (is.array(values))
    values <- array(values, dim = dims_out)

  # get the index in flat python format, as a tensor
  index <- flatten_rowwise(dummy_out)

  # function to return dimensions of output
  dimfun <- function (elem_list)
    dims_out

  # create operation node, passing call and dims as additional arguments
  op('extract',
     x,
     dimfun = dimfun,
     operation_args = list(nelem = nelem,
                           index = index,
                           dims_out = dims_out),
     tf_operation = tf_extract,
     value = values)

}

# replace syntax for greta array objects
#' @export
`[<-.greta_array` <- function(x, ..., value) {

  if (inherits(x$node, 'variable_node')) {
    stop ('cannot replace values in a variable greta array',
         call. = FALSE)
  }

  # rename value since it is confusing when passed to the op
  replacement <- as.greta_array(value)

  # store the full call to mimic on a dummy array, plus the array's dimensions
  call <- sys.call()
  dims <- dim(x)

  # create a dummy array containing the order of elements Python-style
  dummy <- dummy(dims)

  # modify the call, switching to primitive subsetting, changing the target
  # object, and ensuring no dropping happens
  call_list <- as.list(call)[-1]
  call_list[[1]] <- as.name("._dummy_in")
  call_list$value <- NULL

  # put dummy in the parent environment & execute there (to evaluate any
  # promises using variables in that environment), then remove
  pf <- parent.frame()
  assign('._dummy_in', dummy, envir = pf)
  dummy_out <- do.call(.Primitive("["), call_list, envir = pf)
  rm('._dummy_in', envir = pf)

  index <- as.vector(dummy_out)

  if (length(index) != length(replacement)) {

    if ((length(index) %% length(replacement)) != 0) {

      stop ('number of items to replace is not a multiple of ',
            'replacement length')

    } else {

      replacement <- rep(replacement, length.out = length(index))

    }
  }

  # function to return dimensions of output
  dimfun <- function (elem_list)
    dims

  # do replace on the values (unknowns or arrays)
  x_value <- x$node$value()
  replacement_value <- replacement$node$value()

  new_value <- x_value
  r_index <- match(index, dummy)
  new_value[r_index] <- replacement_value

  # if either parent has an unknowns array as a value, coerce this to unknowns
  if (inherits(x_value, 'unknowns') | inherits(replacement_value, 'unknowns'))
    new_value <- as.unknowns(new_value)

  # create operation node, passing call and dims as additional arguments
  op('replace',
     x,
     replacement,
     dimfun = dimfun,
     operation_args = list(index = index,
                           dims = dims),
     value = new_value,
     tf_operation = tf_replace)

}

#' @export
cbind.greta_array <- function (...) {

  dimfun <- function (elem_list) {

    dims <- lapply(elem_list, dim)
    ndims <- vapply(dims, length, FUN.VALUE = 1)
    if (!all(ndims == 2))
      stop ('all greta arrays must be two-dimensional')

    # dimensions
    rows <- vapply(dims, `[`, 1, FUN.VALUE = 1)
    cols <- vapply(dims, `[`, 2, FUN.VALUE = 1)

    # check all the same
    if (!all(rows == rows[1]))
      stop ('all greta arrays must be have the same number of rows',
            call. = FALSE)

    # output dimensions
    c(rows[1], sum(cols))

  }

  op('cbind', ..., dimfun = dimfun,
     tf_operation = tf_cbind)

}

#' @export
rbind.greta_array <- function (...) {

  dimfun <- function (elem_list) {

    dims <- lapply(elem_list, dim)
    ndims <- vapply(dims, length, FUN.VALUE = 1)
    if (!all(ndims == 2))
      stop ('all greta arrays must be two-dimensional')

    # dimensions
    rows <- vapply(dims, `[`, 1, FUN.VALUE = 1)
    cols <- vapply(dims, `[`, 2, FUN.VALUE = 1)

    # check all the same
    if (!all(cols == cols[1]))
      stop ('all greta arrays must be have the same number of columns',
            call. = FALSE)

    # output dimensions
    c(sum(rows), cols[1])

  }

  op('rbind', ..., dimfun = dimfun,
     tf_operation = tf_rbind)

}

#' @export
c.greta_array <- function (...) {

  # loop through arrays, flattening them R-style
  arrays <- lapply(list(...), flatten)

  # get output dimensions
  length_vec <- vapply(arrays, length, FUN.VALUE = 1)
  dim_out <- c(sum(length_vec), 1L)

  # get the output dimension
  dimfun <- function (elem_list)
    dim_out

  # create the op, expanding 'arrays' out to match op()'s dots input
  do.call(op,
          c(operation = 'rbind',
            arrays,
            dimfun = dimfun,
            tf_operation = tf_rbind))

}

#' @export
rep.greta_array <- function (x, ...) {

  # get the index
  idx <- rep(seq_along(x), ...)

  # apply (implicitly coercing to a column vector)
  x[idx]

}


# get dimensions
#' @export
dim.greta_array <- function(x)
  as.integer(x$node$dim)

#' @export
length.greta_array <- function(x)
  prod(dim(x))

# reshape greta arrays
#' @export
`dim<-.greta_array` <- function (x, value) {

  dims <- value

  if (is.null(dims))
    dims <- length(x)

  if (length(dims) == 0L)
    stop ("length-0 dimension vector is invalid",
          call. = FALSE)

  if (length(dims) == 1L)
    dims <- c(dims, 1L)

  if (any(is.na(dims)))
    stop("the dims contain missing values",
         call. = FALSE)

  dims <- as.integer(dims)

  if (any(dims < 0L))
    stop ("the dims contain negative values",
          call. = FALSE)

  prod_dims <- prod(dims)
  len <- length(x)

  if (prod_dims != len) {
    msg <- sprintf("dims [product %i] do not match the length of object [%i]",
                   prod_dims, len)
    stop (msg, call. = FALSE)
  }

  dimfun <- function (elem_list)
    dims

  new_value <- x$node$value()
  dim(new_value) <- dims

  op("reshape",
     x,
     operation_args = list(shape = dims),
     tf_operation = tf$reshape,
     dimfun = dimfun,
     value = new_value)

}

# head handles matrices differently to arrays, so explicitly handle 2D greta
# arrays
#' @export
#' @importFrom utils head
head.greta_array <- function (x, n = 6L, ...) {

  stopifnot(length(n) == 1L)

  # if x is matrix-like, take the top n rows
  if (length(dim(x)) == 2) {

    nrx <- nrow(x)
    if (n < 0L)
      n <- max(nrx + n, 0L)
    else
      n <- min(n, nrx)

    ans <- x[seq_len(n), , drop = FALSE]

  } else {
    # otherwise, take the first n elements

    if (n < 0L)
      n <- max(length(x) + n, 0L)
    else
      n <- min(n, length(x))

    ans <- x[seq_len(n)]

  }

  ans

}

#' @export
#' @importFrom utils tail
tail.greta_array <- function (x, n = 6L, ...) {

  stopifnot(length(n) == 1L)

  # if x is matrix-like, take the top n rows
  if (length(dim(x)) == 2) {

    nrx <- nrow(x)

    if (n < 0L)
      n <- max(nrx + n, 0L)
    else
      n <- min(n, nrx)

    sel <- as.integer(seq.int(to = nrx, length.out = n))
    ans <- x[sel, , drop = FALSE]

  } else {
    # otherwise, take the first n elements

    xlen <- length(x)

    if (n < 0L)
      n <- max(xlen + n, 0L)
    else
      n <- min(n, xlen)

    ans <- x[seq.int(to = xlen, length.out = n)]

  }

  ans

}
