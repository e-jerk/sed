#!/bin/bash
# GNU sed compatibility tests for e-jerk sed
# These tests are derived from GNU sed test patterns

SED=${SED:-"$(dirname "$0")/zig-out/bin/sed"}
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

passed=0
failed=0
skipped=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
    ((passed++))
    echo -e "${GREEN}PASS${NC}: $1"
}

fail() {
    ((failed++))
    echo -e "${RED}FAIL${NC}: $1"
    if [ -n "$2" ]; then
        echo "  Expected: $2"
        echo "  Got: $3"
    fi
}

skip() {
    ((skipped++))
    echo -e "${YELLOW}SKIP${NC}: $1"
}

echo "========================================="
echo "GNU sed compatibility tests"
echo "Testing: $SED"
echo "========================================="
echo

echo "--- Basic Substitution ---"

# Test 1: Simple substitution
result=$(echo "hello world" | $SED 's/world/universe/' 2>/dev/null)
if [ "$result" = "hello universe" ]; then
    pass "Simple substitution"
else
    fail "Simple substitution" "hello universe" "$result"
fi

# Test 2: Global substitution
result=$(echo "aaa" | $SED 's/a/b/g' 2>/dev/null)
if [ "$result" = "bbb" ]; then
    pass "Global substitution (s///g)"
else
    fail "Global substitution (s///g)" "bbb" "$result"
fi

# Test 3: First occurrence only
result=$(echo "aaa" | $SED 's/a/b/' 2>/dev/null)
if [ "$result" = "baa" ]; then
    pass "First occurrence only"
else
    fail "First occurrence only" "baa" "$result"
fi

# Test 4: Case-insensitive substitution
result=$(echo "Hello HELLO hello" | $SED 's/hello/hi/gi' 2>/dev/null)
if [ "$result" = "hi hi hi" ]; then
    pass "Case-insensitive substitution (s///gi)"
else
    fail "Case-insensitive substitution (s///gi)" "hi hi hi" "$result"
fi

# Test 5: No match - output unchanged
result=$(echo "hello" | $SED 's/xyz/abc/' 2>/dev/null)
if [ "$result" = "hello" ]; then
    pass "No match leaves input unchanged"
else
    fail "No match leaves input unchanged" "hello" "$result"
fi

echo
echo "--- Multiple Lines ---"

# Test 6: Multiple lines
cat > "$TMPDIR/multi.txt" << 'EOF'
line one
line two
line three
EOF
result=$($SED 's/line/row/g' "$TMPDIR/multi.txt" 2>/dev/null | grep -c "row")
if [ "$result" -eq 3 ]; then
    pass "Multiple lines substitution"
else
    fail "Multiple lines substitution" "3 rows" "$result rows"
fi

# Test 7: Stdin input
result=$(echo -e "foo\nbar\nfoo" | $SED 's/foo/baz/g' 2>/dev/null | grep -c "baz")
if [ "$result" -eq 2 ]; then
    pass "Stdin multiline input"
else
    fail "Stdin multiline input" "2 baz" "$result baz"
fi

echo
echo "--- Delete Command ---"

# Test 8: Delete matching lines
cat > "$TMPDIR/delete.txt" << 'EOF'
keep this
delete this pattern
keep this too
pattern here also
EOF
result=$($SED '/pattern/d' "$TMPDIR/delete.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Delete matching lines (/pattern/d)"
else
    fail "Delete matching lines (/pattern/d)" "2" "$result"
fi

# Test 9: Delete comment lines
cat > "$TMPDIR/comments.txt" << 'EOF'
# comment
code
# another comment
more code
EOF
result=$($SED '/^#/d' "$TMPDIR/comments.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Delete comment lines (/^#/d)"
else
    fail "Delete comment lines (/^#/d)" "2" "$result"
fi

echo
echo "--- Transliterate ---"

# Test 10: Transliterate (y command)
result=$(echo "abc" | $SED 'y/abc/xyz/' 2>/dev/null)
if [ "$result" = "xyz" ]; then
    pass "Transliterate (y/abc/xyz/)"
else
    fail "Transliterate (y/abc/xyz/)" "xyz" "$result"
fi

# Test 11: Transliterate lowercase to uppercase
result=$(echo "hello" | $SED 'y/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/' 2>/dev/null)
if [ "$result" = "HELLO" ]; then
    pass "Transliterate to uppercase"
else
    fail "Transliterate to uppercase" "HELLO" "$result"
fi

echo
echo "--- Expression Option ---"

# Test 12: -e option for script
result=$(echo "hello" | $SED -e 's/h/H/' 2>/dev/null)
if [ "$result" = "Hello" ]; then
    pass "Expression option (-e)"
else
    fail "Expression option (-e)" "Hello" "$result"
fi

# Test 12a: Multiple -e expressions
result=$(echo "hello world" | $SED -e 's/hello/hi/' -e 's/world/there/' 2>/dev/null)
if [ "$result" = "hi there" ]; then
    pass "Multiple -e expressions"
else
    fail "Multiple -e expressions" "hi there" "$result"
fi

# Test 12b: Three -e expressions
result=$(echo "abc def ghi" | $SED -e 's/abc/AAA/' -e 's/def/BBB/' -e 's/ghi/CCC/' 2>/dev/null)
if [ "$result" = "AAA BBB CCC" ]; then
    pass "Three -e expressions"
else
    fail "Three -e expressions" "AAA BBB CCC" "$result"
fi

# Test 12c: Chained substitution (output of one is input to next)
result=$(echo "cat" | $SED -e 's/cat/bat/' -e 's/bat/rat/' 2>/dev/null)
if [ "$result" = "rat" ]; then
    pass "Chained substitution (-e)"
else
    fail "Chained substitution (-e)" "rat" "$result"
fi

# Test 12d: Mixed commands with multiple -e
result=$(echo -e "foo\nbar\nfoo" | $SED -e 's/foo/baz/' -e '/bar/d' 2>/dev/null)
expected=$(printf "baz\nbaz")
if [ "$result" = "$expected" ]; then
    pass "Mixed commands with multiple -e"
else
    fail "Mixed commands with multiple -e" "$expected" "$result"
fi

echo
echo "--- Line Addressing ---"

# Test 12e: Single line address
result=$(echo -e "line1\nline2\nline3" | $SED '2s/line/LINE/' 2>/dev/null)
expected=$(printf "line1\nLINE2\nline3")
if [ "$result" = "$expected" ]; then
    pass "Single line address (2s/...)"
else
    fail "Single line address (2s/...)" "$expected" "$result"
fi

# Test 12f: Range address
result=$(echo -e "a\nb\nc\nd\ne" | $SED '2,4s/./X/' 2>/dev/null)
expected=$(printf "a\nX\nX\nX\ne")
if [ "$result" = "$expected" ]; then
    pass "Range address (2,4s/...)"
else
    fail "Range address (2,4s/...)" "$expected" "$result"
fi

# Test 12g: Range to end
result=$(echo -e "a\nb\nc\nd" | $SED '3,$s/./X/' 2>/dev/null)
expected=$(printf "a\nb\nX\nX")
if [ "$result" = "$expected" ]; then
    pass "Range to end (3,\$s/...)"
else
    fail "Range to end (3,\$s/...)" "$expected" "$result"
fi

# Test 12h: Last line address
result=$(echo -e "a\nb\nc" | $SED '$s/c/LAST/' 2>/dev/null)
expected=$(printf "a\nb\nLAST")
if [ "$result" = "$expected" ]; then
    pass "Last line address (\$s/...)"
else
    fail "Last line address (\$s/...)" "$expected" "$result"
fi

# Test 12i: Delete by line number
result=$(echo -e "a\nb\nc\nd" | $SED '2d' 2>/dev/null)
expected=$(printf "a\nc\nd")
if [ "$result" = "$expected" ]; then
    pass "Delete by line number (2d)"
else
    fail "Delete by line number (2d)" "$expected" "$result"
fi

# Test 12j: Delete range
result=$(echo -e "a\nb\nc\nd\ne" | $SED '2,4d' 2>/dev/null)
expected=$(printf "a\ne")
if [ "$result" = "$expected" ]; then
    pass "Delete range (2,4d)"
else
    fail "Delete range (2,4d)" "$expected" "$result"
fi

echo
echo "--- File Operations ---"

# Test 13: Read from file
echo "test content" > "$TMPDIR/input.txt"
result=$($SED 's/test/new/' "$TMPDIR/input.txt" 2>/dev/null)
if [ "$result" = "new content" ]; then
    pass "Read from file"
else
    fail "Read from file" "new content" "$result"
fi

# Test 14: In-place edit (if supported)
echo "original" > "$TMPDIR/inplace.txt"
if $SED --help 2>&1 | grep -q "\-i"; then
    $SED -i 's/original/modified/' "$TMPDIR/inplace.txt" 2>/dev/null
    result=$(cat "$TMPDIR/inplace.txt")
    if [ "$result" = "modified" ]; then
        pass "In-place edit (-i)"
    else
        fail "In-place edit (-i)" "modified" "$result"
    fi
else
    skip "In-place edit (-i) not supported"
fi

echo
echo "--- Exit Codes ---"

# Test 15: Exit 0 on success
echo "test" | $SED 's/test/pass/' > /dev/null 2>&1
if [ $? -eq 0 ]; then
    pass "Exit 0 on success"
else
    fail "Exit 0 on success" "0" "$?"
fi

# Test 16: Handle empty input
result=$(echo "" | $SED 's/x/y/' 2>/dev/null)
ec=$?
if [ $ec -eq 0 ]; then
    pass "Handle empty input"
else
    fail "Handle empty input" "exit 0" "exit $ec"
fi

echo
echo "--- Edge Cases ---"

# Test 17: Special characters in replacement
result=$(echo "path/to/file" | $SED 's|/|_|g' 2>/dev/null)
if [ "$result" = "path_to_file" ]; then
    pass "Alternate delimiter (s|x|y|)"
else
    fail "Alternate delimiter (s|x|y|)" "path_to_file" "$result"
fi

# Test 18: Empty pattern (delete all)
result=$(echo "abc" | $SED 's/a//g' 2>/dev/null)
if [ "$result" = "bc" ]; then
    pass "Empty replacement (delete character)"
else
    fail "Empty replacement (delete character)" "bc" "$result"
fi

# Test 19: Long line handling
long_line=$(python3 -c "print('x' * 10000)")
result=$(echo "$long_line" | $SED 's/x/y/g' 2>/dev/null | head -c 10)
if [ "$result" = "yyyyyyyyyy" ]; then
    pass "Long line handling"
else
    fail "Long line handling" "yyyyyyyyyy" "$result"
fi

# Test 20: Unicode handling
result=$(echo "café" | $SED 's/café/coffee/' 2>/dev/null)
if [ "$result" = "coffee" ]; then
    pass "Unicode handling"
else
    fail "Unicode handling" "coffee" "$result"
fi

echo
echo "--- Replacement Special Characters ---"

# Test 21: & expands to matched text
result=$(echo "hello world" | $SED 's/world/[&]/' 2>/dev/null)
if [ "$result" = "hello [world]" ]; then
    pass "& expands to matched text"
else
    fail "& expands to matched text" "hello [world]" "$result"
fi

# Test 22: & with global flag
result=$(echo "foo bar foo" | $SED 's/foo/<&>/g' 2>/dev/null)
if [ "$result" = "<foo> bar <foo>" ]; then
    pass "& with global flag"
else
    fail "& with global flag" "<foo> bar <foo>" "$result"
fi

# Test 23: Escaped & (literal ampersand)
result=$(echo "hello" | $SED 's/hello/a \& b/' 2>/dev/null)
if [ "$result" = "a & b" ]; then
    pass "Escaped & (literal ampersand)"
else
    fail "Escaped & (literal ampersand)" "a & b" "$result"
fi

# Test 24: Multiple & in replacement
result=$(echo "foo" | $SED 's/foo/&-&-&/' 2>/dev/null)
if [ "$result" = "foo-foo-foo" ]; then
    pass "Multiple & in replacement"
else
    fail "Multiple & in replacement" "foo-foo-foo" "$result"
fi

# Test 25: & with case-insensitive match
result=$(echo "Hello" | $SED 's/hello/[&]/i' 2>/dev/null)
if [ "$result" = "[Hello]" ]; then
    pass "& with case-insensitive match preserves original case"
else
    fail "& with case-insensitive match preserves original case" "[Hello]" "$result"
fi

# Test 26: Escape sequence \n in replacement
result=$(echo "a b" | $SED 's/ /\n/' 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" = "2" ]; then
    pass "Escape sequence \\n in replacement"
else
    fail "Escape sequence \\n in replacement" "2 lines" "$result lines"
fi

# Test 27: Escape sequence \t in replacement
result=$(echo "a b" | $SED 's/ /\t/' 2>/dev/null)
expected=$(printf "a\tb")
if [ "$result" = "$expected" ]; then
    pass "Escape sequence \\t in replacement"
else
    fail "Escape sequence \\t in replacement" "$expected" "$result"
fi

echo
echo "========================================="
echo "Results: $passed passed, $failed failed, $skipped skipped"
echo "========================================="

if [ $failed -gt 0 ]; then
    exit 1
fi
exit 0
