/// CLI entry point for cub.

/// Entry point.
fn main {
  @async.run_async_main(
    async fn() {
      let args = @env.args()
      if args.length() > 1 {
        println("cub: \{args[1]}")
      } else {
        println("cub")
      }
    },
  )
}
