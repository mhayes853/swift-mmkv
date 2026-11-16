import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { reportResults, runChecks, type CheckResult } from './checks';

export default function App() {
  const [results, setResults] = useState<CheckResult[]>();

  useEffect(() => {
    const results = runChecks();
    reportResults(results);
    setResults(results);
  }, []);

  const failed = results?.filter((result) => !result.passed).length ?? 0;
  return (
    <View style={styles.container}>
      <Text style={styles.title} testID="summary">
        {results === undefined
          ? 'Running…'
          : failed === 0
            ? `All ${results.length} checks passed`
            : `${failed} of ${results.length} checks failed`}
      </Text>
      <ScrollView>
        {results?.map((result) => (
          <View key={result.name} style={styles.row}>
            <Text style={styles.name}>
              {result.passed ? '✅' : '❌'} {result.name}
            </Text>
            {result.error !== undefined && <Text style={styles.error}>{result.error}</Text>}
          </View>
        ))}
      </ScrollView>
      <StatusBar style="auto" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff', paddingTop: 80, paddingHorizontal: 20 },
  title: { fontSize: 22, fontWeight: '600', marginBottom: 16 },
  row: { marginBottom: 12 },
  name: { fontSize: 16 },
  error: { fontSize: 13, color: '#b00020', marginTop: 4 },
});
