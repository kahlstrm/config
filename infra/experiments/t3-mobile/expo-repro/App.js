import { useEffect, useState } from 'react';
import { Button, ScrollView, StyleSheet, Text, View } from 'react-native';
import * as Network from 'expo-network';

const time = () => new Date().toISOString().slice(11, 19);
const describe = (state) => `isConnected=${state.isConnected} type=${state.type}`;

export default function App() {
  const state = Network.useNetworkState();
  const [log, setLog] = useState([]);
  const append = (line) => setLog((lines) => [`${time()} ${line}`, ...lines].slice(0, 30));

  useEffect(() => {
    const subscription = Network.addNetworkStateListener((event) => append(`event ${describe(event)}`));
    return () => subscription.remove();
  }, []);

  return (
    <View style={styles.container}>
      <Text style={styles.state}>useNetworkState: {describe(state)}</Text>
      <Button
        title="getNetworkStateAsync"
        onPress={async () => append(`read ${describe(await Network.getNetworkStateAsync())}`)}
      />
      <ScrollView>
        {log.map((line, index) => (
          <Text key={index}>{line}</Text>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 24, paddingTop: 64, gap: 12 },
  state: { fontSize: 18, fontWeight: 'bold' },
});
