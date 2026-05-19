// Test workflow for the LazyMap thread-safety regression guard
// (https://github.com/nf-core/viralmetagenome/issues/290).
//
// The RACE workflow:
//   1. writes a large nested JSON to a temp file,
//   2. repeatedly parses it and races hashCode() on the nested map from
//      `n_threads` threads aligned by a CyclicBarrier,
//   3. emits:
//        - errors      : how many NPEs were observed across all rounds
//        - inner_class : FQN of whatever `inner` ended up being (sanity check
//                        — should be LazyMap for vanilla, HashMap for current)
//        - first_error : the first NPE message we caught, or '' if none. Lets
//                        the test assert on the actual exception text instead
//                        of a bare count.
//
// The `mode` input selects which parser to test:
//   - 'vanilla' : new groovy.json.JsonSlurper() — the previous broken pattern,
//                 MUST produce NPEs (otherwise the guard isn't biting).
//   - 'current' : getMapFromJson() from main.nf — MUST produce zero NPEs.

include { getMapFromJson } from '../main.nf'

def writeBigJson(int nested_keys) {
    def sb = new StringBuilder(64 + nested_keys * 24)
    sb << '{"cluster_id":"cl17","nested":{'
    nested_keys.times { i ->
        if (i) sb << ','
        sb << "\"k_${i}\":${i}"
    }
    sb << '}}'
    def tmp = java.nio.file.Files.createTempFile("lazymap_race", ".json")
    tmp.text = sb.toString()
    return tmp
}

workflow RACE {
    take:
    mode             // 'vanilla' | 'current'
    n_threads        // race width
    max_rounds       // hard upper bound on iterations
    time_budget_s    // wall-clock budget per run
    nested_keys      // size of the nested object — bigger = wider race window

    main:
    String race_mode = mode as String
    int    threads   = n_threads as int
    int    cap       = max_rounds as int
    long   deadline  = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(time_budget_s as int)
    def    json_file = writeBigJson(nested_keys as int)
    def    npe_count = new java.util.concurrent.atomic.AtomicInteger(0)
    def    inner_fqn = new java.util.concurrent.atomic.AtomicReference<String>('')
    def    first_npe = new java.util.concurrent.atomic.AtomicReference<String>('')
    def    pool      = java.util.concurrent.Executors.newFixedThreadPool(threads)

    // not allowed to use a while loop
    (1..cap).find { _i ->
        if (System.nanoTime() >= deadline) {
            return true
        }
        // Fresh parse each round — the race only fires on the first hashCode()
        // of a given LazyMap instance.
        // .get('nested') triggers buildIfNeeded on the OUTER LazyMap but
        // leaves the inner one unbuilt, so the race window stays wide.
        def inner = (race_mode == 'vanilla')
            ? new groovy.json.JsonSlurper().parseText(json_file.text).get('nested')
            : getMapFromJson(json_file).get('nested')

        // Sanity check: record what we're actually racing against. compareAndSet
        // only writes on the first round; later rounds are no-ops.
        inner_fqn.compareAndSet('', inner.getClass().name)

        def barrier = new java.util.concurrent.CyclicBarrier(threads)
        def latch   = new java.util.concurrent.CountDownLatch(threads)
        threads.times {
            pool.submit {
                try {
                    barrier.await()
                    inner.hashCode()
                }
                catch (Throwable t) {
                    if (t instanceof NullPointerException || t.cause instanceof NullPointerException) {
                        npe_count.incrementAndGet()
                        // Capture the first NPE's class + message so the test
                        // can assert on the actual exception text.
                        first_npe.compareAndSet('', "${t.class.simpleName}: ${t.message}".toString())
                    }
                }
                latch.countDown()
            }
        }
        latch.await(5, java.util.concurrent.TimeUnit.SECONDS)
        return false
    }
    pool.shutdownNow()
    pool.awaitTermination(5, java.util.concurrent.TimeUnit.SECONDS)
    java.nio.file.Files.deleteIfExists(json_file)

    println "[RACE/${race_mode}] inner class : ${inner_fqn.get()}"
    println "[RACE/${race_mode}] NPE count   : ${npe_count.get()}"
    println "[RACE/${race_mode}] first error : ${first_npe.get() ?: '(none)'}"

    emit:
    errors      = Channel.value(npe_count.get())
    inner_class = Channel.value(inner_fqn.get())
    first_error = Channel.value(first_npe.get())
}
