// Prints the checks the app ran, and fails if any of them did.
const { results } = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));

for (const { name, passed, error } of results) {
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${name}${error ? `\n      ${error}` : ''}`);
}
const failed = results.filter((result) => !result.passed).length;
console.log(`\n${results.length - failed} of ${results.length} checks passed.`);
process.exit(failed === 0 && results.length > 0 ? 0 : 1);
