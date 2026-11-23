#!/bin/zsh
# The driver of ocr-crash-guard.test.js: writes the "engine was loading" marker (ocrEngineLoading) into the test
# instance's settings suite when the page asks ("TEST marker gpu" / "TEST marker cpu" in the app log: as if meikiocr had
# crashed MacPopup while loading on the GPU, or on the CPU), and once the page is done, checks that the engine is now
# listed as running on the CPU (ocrEnginesOnCPU) and that no marker is left. Runs with RUN and SUITE set (launch.sh).
end=$((SECONDS + 110))
done_markers=()
until grep -q '^\[web\] TEST done' "$RUN/app.log" 2>/dev/null; do
    (( SECONDS > end )) && { echo "TEST FAIL the driver timed out waiting for the page"; exit 0; }
    for kind in gpu cpu; do
        if [[ ${done_markers[(Ie)$kind]} -eq 0 ]] && grep -q "TEST marker $kind" "$RUN/app.log" 2>/dev/null; then
            [[ $kind == cpu ]] && cpu=true || cpu=false
            defaults write "$SUITE" ocrEngineLoading -dict engine meikiocr cpu -bool $cpu
            done_markers+=($kind)
            echo "TEST marker $kind written"
        fi
    done
    sleep 0.1
done
onCPU=$(defaults read "$SUITE" ocrEnginesOnCPU 2>/dev/null)
if [[ "$onCPU" == *meikiocr* ]]; then
    echo "TEST ok ocrEnginesOnCPU lists meikiocr"
else
    echo "TEST FAIL ocrEnginesOnCPU lists meikiocr: ${onCPU:-none}"
fi
if defaults read "$SUITE" ocrEngineLoading >/dev/null 2>&1; then
    echo "TEST FAIL no loading marker is left: $(defaults read "$SUITE" ocrEngineLoading | tr -s ' \n' ' ')"
else
    echo "TEST ok no loading marker is left"
fi
