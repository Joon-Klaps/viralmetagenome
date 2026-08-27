// Shared helpers for the pipeline-level nf-tests.
//
// nf-test adds `tests/lib` (the default `libDir`) to the classpath automatically,
// so this class is available inside any .nf.test file without an import.
//
// Everything here is a static *closure*, not a static method. That is deliberate:
// `getAllFilesFromDir`, `removeNextflowVersion`, `path`, `bam`, `snapshot`,
// `workflow` and friends are nf-test DSL methods that only exist on the delegate
// of a running test. A closure has its delegate rebound when it is called from
// inside `then {}`, so those names resolve. A plain static method would fail with
// "No such property/method".
//
// A test file becomes a list of scenarios plus one line:
//
//     def scenarios = [ [ name: "-profile test", scope: "files", bam: true ] ]
//     scenarios.each { scenario -> test(scenario.name, UTILS.getTest(scenario)) }
//
// Scenario keys
// -------------
//   name          required. The nf-test test name.
//   scope         "files" | "multiqc" | "versions". Default "multiqc".
//                   files    - whole outdir: stable names + stable contents
//                   multiqc  - the multiqc/ subtree only
//                   versions - task count + versions.yml only (params matrices)
//   bam           true to add per-BAM samtools statistics (implies scope "files").
//   vcf           true to add per-VCF variants md5 (implies scope "files").
//   params        map merged into the `when { params { } }` block.
//   overview      true to snapshot the overview-tables CSV column names/values.
//   sort_overview true to sort overview column names (test_group did this).
//   stub          true to run with -stub.
//   failure       true if the run is expected to fail.
//   tag           extra nf-test tag.
//   ignoreFiles   extra glob(s) excluded from the stable-content assertion.
//   warnings      true to snapshot filtered Nextflow warnings.

class UTILS {

    // Log lines that legitimately vary between runs, machines and Nextflow
    // versions. Snapshotting them produces failures that say nothing about the
    // pipeline.
    public static def SNAPSHOT_IGNORE = [
        "Access to undefined parameter",
        "Creating env using",
        "Downloading plugin",
        "Got an interrupted exception while taking agent result",
        "Pulling Singularity image",
        "publishDir path contains a variable with a null value",
        "Staging foreign file",
        "Unable to resume cached task",
        "Unable to stage foreign file",
    ]

    public static def VERSIONS_YML = "pipeline_info/nf_core_viralmetagenome_software_mqc_versions.yml"

    // Builds the ordered list handed to snapshot(). Keeping the order fixed here
    // is what makes snapshots comparable across test files.
    public static def getAssertions = { Map args ->
        def outdir = args.outdir
        def scenario = args.scenario ?: [:]
        def workflow = args.workflow

        def scope = scenario.scope ?: "multiqc"
        def ignoreFiles = scenario.ignoreFiles ? [scenario.ignoreFiles].flatten() : []
        def assertion = []

        // A failing run has no meaningful task count or versions file.
        if (!scenario.failure) {
            assertion.add(workflow.trace.succeeded().size())
            assertion.add(removeNextflowVersion("${outdir}/${VERSIONS_YML}"))
        }

        if (scope == "files") {
            assertion.add(
                getAllFilesFromDir(
                    outdir,
                    relative: true,
                    includeDir: true,
                    ignore: ['pipeline_info/*.{html,json,txt}'] + ignoreFiles
                )
            )

            // Stub runs produce empty placeholder files; hashing them is noise.
            if (!scenario.stub) {
                assertion.add(
                    getAllFilesFromDir(outdir, ignoreFile: 'tests/.nftignore', ignore: ignoreFiles)
                )

                if (scenario.bam) {
                    def bam_files = getAllFilesFromDir(outdir, include: ['**/*.bam'], ignore: ignoreFiles)
                    assertion.add(
                        bam_files.isEmpty()
                            ? 'No BAM files'
                            : bam_files.collect { file -> [file.getName(), bam(file.toString()).getStatistics()] }
                    )
                }

                if (scenario.vcf) {
                    def vcf_files = getAllFilesFromDir(outdir, include: ['**/*.vcf.gz'], ignore: ignoreFiles)
                    assertion.add(
                        vcf_files.isEmpty()
                            ? 'No VCF files'
                            : vcf_files.collect { file -> [file.getName(), path(file.toString()).vcf.getVariantsMD5()] }
                    )
                }
            }
        }
        else if (scope == "multiqc") {
            assertion.add(
                getAllFilesFromDir(outdir, include: ['multiqc/**'], relative: true, includeDir: false)
            )
            if (!scenario.stub) {
                assertion.add(
                    getAllFilesFromDir(
                        outdir,
                        include: ['multiqc/**'],
                        ignoreFile: 'tests/.nftignore',
                        ignore: ignoreFiles
                    )
                )
            }
        }
        // scope == "versions" adds nothing beyond task count + versions.yml.

        if (scenario.overview) {
            def samples = path("${outdir}/overview-tables/samples_overview.tsv").csv(sep: "\t")
            def contigs = path("${outdir}/overview-tables/contigs_overview-with-iterations.tsv").csv(sep: "\t")
            assertion.add(scenario.sort_overview ? samples.columnNames.sort() : samples.columnNames)
            assertion.add(samples.columns["sample"].sort())
            assertion.add(scenario.sort_overview ? contigs.columnNames.sort() : contigs.columnNames)
            assertion.add(contigs.columns["index"].sort())
        }

        if (scenario.warnings) {
            def std = workflow.stderr + workflow.stdout
            assertion.add(
                filterNextflowOutput(
                    std,
                    include: ["WARN"],
                    ignore: SNAPSHOT_IGNORE + (scenario.snapshot_ignore ?: [])
                ) ?: "No warnings"
            )
        }

        return assertion
    }

    // Returns the body of an nf-test `test(...)` block for one scenario.
    public static def getTest = { scenario ->
        return {
            tag "pipeline"
            if (scenario.tag) {
                tag scenario.tag
            }
            if (scenario.failure) {
                tag "failure"
            }
            if (scenario.stub) {
                options "-stub"
            }

            when {
                params {
                    outdir = "${outputDir}"
                    (scenario.params ?: [:]).each { key, value ->
                        delegate."$key" = value
                    }
                }
            }

            then {
                if (scenario.failure) {
                    assert workflow.failed
                }
                else {
                    assert workflow.success
                }

                assertAll(
                    {
                        assert snapshot(
                            *UTILS.getAssertions(
                                outdir: params.outdir,
                                scenario: scenario,
                                workflow: workflow
                            )
                        ).match()
                    }
                )
            }
        }
    }
}
