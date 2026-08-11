@{
    # Installer entry points intentionally expose imperative verbs, plural contract names,
    # and cross-module variables that static per-file analysis cannot resolve.
    ExcludeRules = @(
        'PSAvoidOverwritingBuiltInCmdlets'
        'PSAvoidUsingWriteHost'
        'PSReviewUnusedParameter'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
}
