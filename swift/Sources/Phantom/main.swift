import PhantomCore

// Single binary, two personalities: a CLI when invoked with a command,
// the agent app otherwise. See PhantomEntry.run().
MainActor.assumeIsolated {
    PhantomEntry.run()
}
