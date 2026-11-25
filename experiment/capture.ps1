param($Version="baseline",$Research="../../retrieval-research")
$exe="./experiment/bin/$Version.exe"
$file="$Research/checkouts/powerpath/pp.ps1"
foreach ($step in "root","191","494","2453","2560","help") {
    $nav = switch ($step) {
        root { @() }
        help { "show","2562-2565" }
        default { "go",$step }
    }
    & $exe $file @nav --plain > "experiment/raw/$Version-$step.txt" 2>&1
}
