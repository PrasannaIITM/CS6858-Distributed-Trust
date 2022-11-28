require("@nomiclabs/hardhat-waffle");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const toWei = (value) => ethers.utils.parseEther(value.toString());
const toBigNumber = (value) => ethers.utils.parseUnits(value.toString(), 9);

const fromWei = (value) =>
    ethers.utils.formatEther(
        typeof value === "string" ? value : value.toString()
    );

const getBalance = ethers.provider.getBalance;

const createExchange = async (factory, tokenAddress, sender) => {
    const exchangeAddress = await factory
        .connect(sender)
        .callStatic.createExchange(tokenAddress);

    await factory.connect(sender).createExchange(tokenAddress);

    const Exchange = await ethers.getContractFactory("Exchange");

    return await Exchange.attach(exchangeAddress);
};

describe("ethToTokenSwap", () => {
    let owner;
    let lp0, lp1;
    let user;
    let exchange;
    let token;

    beforeEach(async () => {
        [owner, lp0, lp1, user] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("Token");
        token = await Token.deploy("TrustToken", "TRUST", toBigNumber(1000000));
        await token.deployed();

        const Exchange = await ethers.getContractFactory("Exchange");
        exchange = await Exchange.deploy(token.address);
        await exchange.deployed();
    });

    it("Test eth to token swap with multiple liquidity providers", async () => {
        // lp0 and lp1 provide liquidity
        // exchange reserves: 10Eth, 500 tokens
        // exchange pool invariant = 10e18 * 500 = 5e21
        await token.approve(exchange.address, toBigNumber(500));
        await token.approve(lp0.address, toBigNumber(250));
        await token.transfer(lp0.address, toBigNumber(250));
        await token.approve(lp1.address, toBigNumber(1000));
        await token.transfer(lp1.address, toBigNumber(1000));
        await token.connect(lp0).approve(exchange.address, toBigNumber(250));
        await token.connect(lp1).approve(exchange.address, toBigNumber(1000));

        await exchange.connect(lp0).addLiquidity(toBigNumber(250), { value: toWei(5) });
        await exchange.connect(lp1).addLiquidity(toBigNumber(1000), { value: toWei(5) });
        expect(await token.balanceOf(lp1.address)).to.eq(toBigNumber(750));

        // user swaps 1 Eth and expects to receive at least 4.5 tokens
        await exchange.connect(user).ethToTokenSwap(toBigNumber(4.5), { value: toWei(1) });
        expect(await token.balanceOf(user.address)).to.eq(toBigNumber(45.351216185));

        // due to exchange fees, the pool invariant increases slightly(5.001136621965e21), but the price does not change
        expect(await getBalance(exchange.address)).to.eq(toWei(11));
        expect(await exchange.getReserve()).to.eq(toBigNumber(500 - 45.351216185));

        // lp0 removes liquidity and gets back eth and tokens proportional to his share in the liquidity pool
        const lp0EtherBalanceBefore = await getBalance(lp0.address);
        const lp0TokenBalanceBefore = await token.balanceOf(lp0.address);
        await exchange.connect(lp0).removeLiquidity(toWei(5));
        const lp0EtherBalanceAfter = await getBalance(lp0.address);
        const lp0TokenBalanceAfter = await token.balanceOf(lp0.address);
        expect(
            fromWei(lp0EtherBalanceAfter.sub(lp0EtherBalanceBefore)))
            .to.equal("5.499922299"); // 5.5 - gas

        expect(
            lp0TokenBalanceAfter.sub(lp0TokenBalanceBefore))
            .to.equal(toBigNumber(227.324391907));
    });

});

describe("tokenToEthSwap", async () => {
    let owner;
    let user;
    let exchange;
    let token;

    beforeEach(async () => {
        [owner, user] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("Token");
        token = await Token.deploy("TrustToken", "TRUST", toBigNumber(1000000));
        await token.deployed();

        const Exchange = await ethers.getContractFactory("Exchange");
        exchange = await Exchange.deploy(token.address);
        await exchange.deployed();

        await token.transfer(user.address, toBigNumber(22));
        await token.connect(user).approve(exchange.address, toBigNumber(22));

        await token.approve(exchange.address, toBigNumber(2000));
        await exchange.addLiquidity(toBigNumber(2000), { value: toWei(1000) });
    });

    it("Test token to eth swap", async () => {
        const userBalanceBefore = await getBalance(user.address);
        const exchangeBalanceBefore = await getBalance(exchange.address);

        await exchange.connect(user).tokenToEthSwap(toBigNumber(2), toWei(0.9));

        const userBalanceAfter = await getBalance(user.address);
        expect(fromWei(userBalanceAfter.sub(userBalanceBefore))).to.equal(
            "0.996445158279683515"  // 0.996505985 - gas
        );

        const userTokenBalance = await token.balanceOf(user.address);
        expect(userTokenBalance).to.equal(toBigNumber(20.0));

        const exchangeBalanceAfter = await getBalance(exchange.address);
        expect(fromWei(exchangeBalanceAfter.sub(exchangeBalanceBefore))).to.equal(
            "-0.996505985279683515"
        );

        const exchangeTokenBalance = await token.balanceOf(exchange.address);
        expect(exchangeTokenBalance).to.equal(toBigNumber(2002.0));
    });
});


describe("tokenToTokenSwap", async () => {
    let owner;
    let user;
    let exchange;
    let token;

    beforeEach(async () => {
        [owner, user] = await ethers.getSigners();
    });

    it("Test token for token swap", async () => {
        const Factory = await ethers.getContractFactory("Factory");
        const Token = await ethers.getContractFactory("Token");

        const factory = await Factory.deploy();
        const token1 = await Token.deploy("TrustTokenA", "TRUSTA", toWei(1000000));
        const token2 = await Token.connect(user).deploy("TrustTokenB", "TRUSTB", toWei(1000000));

        await factory.deployed();
        await token1.deployed();
        await token2.deployed();

        const exchange1 = await createExchange(factory, token1.address, owner);
        const exchange2 = await createExchange(factory, token2.address, user);

        await token1.approve(exchange1.address, toWei(2000));
        await exchange1.addLiquidity(toWei(2000), { value: toWei(1000) });

        await token2.connect(user).approve(exchange2.address, toWei(1000));
        await exchange2.connect(user).addLiquidity(toWei(1000), { value: toWei(1000) });

        expect(await token2.balanceOf(owner.address)).to.equal(0);

        await token1.approve(exchange1.address, toWei(10));
        await exchange1.tokenToTokenSwap(toWei(10), toWei(4.8), token2.address);

        expect(fromWei(await token2.balanceOf(owner.address))).to.equal(
            "4.925956256854949537"
        );

        expect(await token1.balanceOf(user.address)).to.equal(0);

        await token2.connect(user).approve(exchange2.address, toWei(10));
        await exchange2
            .connect(user)
            .tokenToTokenSwap(toWei(10), toWei(19.6), token1.address);

        expect(fromWei(await token1.balanceOf(user.address))).to.equal(
            "19.898684427080450088"
        );
    });
});
