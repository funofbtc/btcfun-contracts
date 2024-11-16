const { ethers, upgrades} = require('hardhat');

const path = require('path');
const fs = require('fs');
require('dotenv').config({ path: path.resolve(__dirname, '../.env') });

const pathOutputJson = path.join(__dirname, '../deploy_output.json');
let deployOutput = {};
if (fs.existsSync(pathOutputJson)) {
  deployOutput = require(pathOutputJson);
}
async function main() {
    let deployer = new ethers.Wallet(process.env.PRIVATE_KEY, ethers.provider)
    console.log(await deployer.getAddress())
    const bridgeFactory = await ethers.getContractFactory("BtcFun", deployer);
   // let bridgeProxy;
    if (deployOutput.bridgeProxy === undefined) {
        console.log(`... contract : undefined`)
      bridgeProxy = await upgrades.deployProxy(
          bridgeFactory,
        [process.env.INITIAL_OWNER],
        {
            initializer: "initialize",
            // constructorArgs: [process.env.INITIAL_OWNER],
            // unsafeAllow: ['constructor', 'state-variable-immutable'],
        });
    console.log('tx hash:', bridgeProxy.deploymentTransaction().hash);
    } else {
      bridgeProxy = bridgeFactory.attach(deployOutput.bridgeProxy);
    }

    console.log('bridgeProxy deployed to:', bridgeProxy.target);
    deployOutput.bridgeProxy = bridgeProxy.target;
    fs.writeFileSync(pathOutputJson, JSON.stringify(deployOutput, null, 1));

    // const tx = await bridgeProxy.sets_([["0x676f7665726e6f72000000000000000000000000000000000000000000000000",process.env.INITIAL_OWNER]]);
    // await tx.wait(1);
    console.log("init ok")

    deployOutput.bridgeProxy = bridgeProxy.target;
    fs.writeFileSync(pathOutputJson, JSON.stringify(deployOutput, null, 1));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
