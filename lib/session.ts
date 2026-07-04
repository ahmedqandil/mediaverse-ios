import * as SecureStore from 'expo-secure-store';
import { SESSION_KEY } from './constants';

export async function getSessionToken(): Promise<string | null> {
  try {
    return await SecureStore.getItemAsync(SESSION_KEY);
  } catch {
    return null;
  }
}

export async function setSessionToken(token: string): Promise<void> {
  await SecureStore.setItemAsync(SESSION_KEY, token);
}

export async function clearSessionToken(): Promise<void> {
  await SecureStore.deleteItemAsync(SESSION_KEY);
}

export async function hasSession(): Promise<boolean> {
  const t = await getSessionToken();
  return !!t;
}
