import GoogleAuthUtilsTest from './GoogleAuthUtils.test'
import abilityTest from './Ability.test';
import tokenBatchTest from './TokenBatch.test';
import assetConcurrencyTest from './AssetConcurrency.test';
import tokenProgressDialogTest from './TokenProgressDialog.test';
import steamSecretStoreTest from './SteamSecretStore.test';
import backupRoundTripTest from './BackupRoundTrip.test';
import localBackupFileIoDeviceTest from './LocalBackupFileIo.test';
import deviceMigrationTest from './DeviceMigration.test';
import bleTransferSmokeTest from './BleTransferSmoke.test';
import wearEngineSmokeTest from './WearEngineSmoke.test';
import cloudBackupIoTest from './CloudBackupIo.test';
import cloudBackupCloudLifecycleTest from './CloudBackupCloudLifecycle.test';
import iconPackPublicationDeviceTest from './IconPackPublication.test';
import { abilityDelegatorRegistry } from '@kit.TestKit';

export default function testsuite() {
  const parameters = abilityDelegatorRegistry.getArguments().parameters;
  if (parameters['iconPackPublicationFixture'] === 'true' || parameters['-s iconPackPublicationFixture'] === 'true') {
    iconPackPublicationDeviceTest();
    return;
  }
  abilityTest();
  GoogleAuthUtilsTest()
  tokenBatchTest();
  assetConcurrencyTest();
  tokenProgressDialogTest();
  steamSecretStoreTest();
  backupRoundTripTest();
  localBackupFileIoDeviceTest();
  deviceMigrationTest();
  bleTransferSmokeTest();
  wearEngineSmokeTest();
  cloudBackupIoTest();
  if (abilityDelegatorRegistry.getArguments().parameters['cloudBackupOwnedFixture'] === 'true') {
    cloudBackupCloudLifecycleTest();
  }
}
