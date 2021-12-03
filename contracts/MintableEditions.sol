// SPDX-License-Identifier: MIT

/**
 * ░█▄█░▄▀▄▒█▀▒▄▀▄░░░▒░░░▒██▀░█▀▄░█░▀█▀░█░▄▀▄░█▄░█░▄▀▀░░░█▄░█▒█▀░▀█▀
 * ▒█▒█░▀▄▀░█▀░█▀█▒░░▀▀▒░░█▄▄▒█▄▀░█░▒█▒░█░▀▄▀░█▒▀█▒▄██▒░░█▒▀█░█▀░▒█▒
 * 
 */

pragma solidity 0.8.6;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC2981Upgradeable, IERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {CountersUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import "./EditionMetadata.sol";
import "./IMintableEditions.sol";

/**
 * This contract allows dynamic NFT minting.
 * 
 * Operations allow for selling publicly, partial or total giveaways, direct giveaways and rewardings.
 */
contract MintableEditions is ERC721Upgradeable, IERC2981Upgradeable, IMintableEditions, OwnableUpgradeable {
    
    using CountersUpgradeable for CountersUpgradeable.Counter;
    
    event PriceChanged(uint256 amount);
    event EditionSold(uint256 price, address owner);
    event PaymentReleased(address to, uint256 amount);
    event PaymentFailed(address to);

    struct Shares {
        address payable holder;
        uint16 bps;
    }

    // token id counter
    CountersUpgradeable.Counter private counter;

    // token description
    string public description;

    // token content URL
    string public contentUrl;
    // hash for the associated content
    bytes32 public contentHash;
    // type of content
    uint8 internal contentType;
    
    // the number of editions this contract can mint
    uint64 public size;
    
    // royalties ERC2981 in bps
    uint8 internal royaltiesType;
    uint16 public royalties;

    
    // NFT rendering logic
    EditionMetadata private immutable metadata;

    // addresses allowed to mint editions
    mapping(address => uint16) internal allowedMinters;

    // price for sale
    uint256 public price;

    address[] private shareholders;
    mapping(address => uint16) public shares;
    mapping(address => uint256) private witdrawals;
    // balance withdrawn so far
    uint256 private withdrawn;

    constructor(EditionMetadata _metadata) initializer {
        metadata = _metadata;
    }

    /**
     * Creates a new edition and sets the only allowed minter to the address that creates/owns the edition: this can be re-assigned or updated later.
     * 
     * @param _owner can authorize, mint, gets royalties and a dividend of sales, can update the content URL.
     * @param _name name of editions, used in the title as "$name $tokenId/$size"
     * @param _symbol symbol of the tokens mined by this contract
     * @param _description description of tokens of this edition
     * @param _contentUrl content URL of the edition tokens
     * @param _contentHash SHA256 of the tokens content in bytes32 format (0xHASH)
     * @param _contentType type of tokens content [0=image, 1=animation/video/audio]
     * @param _size number of NFTs that can be minted from this contract: set to 0 for unbound
     * @param _royalties perpetual royalties paid to the creator upon token selling
     * @param _shares shares in bps destined to the shareholders (one per each shareholder)
     */
    function initialize(
        address _owner,
        string memory _name,
        string memory _symbol,
        string memory _description,
        string memory _contentUrl,
        bytes32 _contentHash,
        uint8 _contentType,
        uint64 _size,
        uint16 _royalties,
        Shares[] memory _shares
    ) public initializer {
        __ERC721_init(_name, _symbol);
        __Ownable_init();

        transferOwnership(_owner); // set ownership
        description = _description;
        contentUrl = _contentUrl;
        contentHash = _contentHash;
        contentType = _contentType;
        size = _size;
        counter.increment(); // token ids start at 1

        require(_royalties < 10_000, "Royalties too high");
        royalties = _royalties;
        
        uint16 _totalShares;
        for (uint256 i = 0; i < _shares.length; i++) {
            _addPayee(_shares[i].holder, _shares[i].bps);
            _totalShares += _shares[i].bps;
        }
        require(_totalShares < 10_000, "Shares too high");
        _addPayee(payable(_owner), 10_000 - _totalShares);
    }

    function _addPayee(address payable _account, uint16 _shares) internal {
        require(_account != address(0), "Shareholder is zero address");
        require(_shares > 0 && _shares <= 10_000, "Shares are invalid");
        require(shares[_account] == 0, "Shareholder already has shares");

        shareholders.push(_account);
        shares[_account] = _shares;
    }

    /**
     * Returns the number of tokens minted so far 
     */
     function totalSupply() public view returns (uint256) {
        return counter.current() - 1;
    }

    /**
     * Basic ETH-based sales operation, performed at the given set price.
     * This operation is open to everyone as soon as the salePrice is set to a non-zero value.
     */
    function purchase() external payable returns (uint256) {
        require(price > 0, "Not for sale");
        require(msg.value == price, "Wrong price");
        address[] memory toMint = new address[](1);
        toMint[0] = msg.sender;
        emit EditionSold(price, msg.sender);
        return _mintEditions(toMint);
    }

    /**
     * This operation sets the sale price, thus allowing anyone to acquire a token from this edition at the sale price via the purchase operation.
     * Setting the sale price to 0 prevents purchase of the tokens which is then allowed only to permitted addresses.
     * 
     * @param _wei if sale price is 0, no sale is allowed, otherwise the provided amount of WEI is needed to start the sale.
     */
    function setPrice(uint256 _wei) external onlyOwner {
        price = _wei;
        emit PriceChanged(price);
    }

    /**
     * This operation transfers all ETHs from the contract balance to the owner and shareholders.
     */
    function withdraw() external {
        for (uint i = 0; i < shareholders.length; i++) {
            try this.withdraw(payable(shareholders[i])) returns (uint256 payment) {
                emit PaymentReleased(shareholders[i], payment);
            } catch {
                emit PaymentFailed(shareholders[i]);
            }
        }
    }

    /**
     * This operation attempts to transfer part of the contract balance to the provided shareholder based on its shares and previous witdrawals.
     *
     * @param a valid shareholder address
     */
    function withdraw(address payable _account) external returns (uint256) {
        uint256 _totalReceived = address(this).balance + withdrawn;
        uint256 _amount = (_totalReceived * shares[_account]) / 10_000 - witdrawals[_account];
        require(_amount != 0, "Account is not due payment");
        witdrawals[_account] += _amount;
        withdrawn += _amount;
        AddressUpgradeable.sendValue(_account, _amount);
        return _amount;
    }

    /**
     * Internal: checks if the msg.sender is allowed to mint.
     */
    function _isAllowedToMint() internal view returns (bool) {
        return (owner() == msg.sender) || _isPublicAllowed() || (allowedMinters[msg.sender] > 0);
    }
    
    /**
     * Internal: checks if the ZeroAddress is allowed to mint.
     */
    function _isPublicAllowed() internal view returns (bool) {
        return (allowedMinters[address(0x0)] > 0);
    }

    /**
     * If caller is listed as an allowed minter, mints one NFT for him.
     */
    function mintEdition() external override returns (uint256) {
        require(_isAllowedToMint(), "Minting not allowed");
        address[] memory toMint = new address[](1);
        toMint[0] = msg.sender;
        if (owner() != msg.sender && !_isPublicAllowed()) {
            allowedMinters[msg.sender] = --allowedMinters[msg.sender];
        }
        return _mintEditions(toMint);
    }

    /**
     * Mints multiple tokens, one for each of the given list of addresses.
     * Only the edition owner can use this operation and it is intended fo partial giveaways.
     * 
     * @param recipients list of addresses to send the newly minted tokens to
     */
    function mintEditions(address[] memory recipients) external onlyOwner override returns (uint256) {
        return _mintEditions(recipients);
    }

    /**
     * Simple override for owner interface.
     */
    function owner() public view override(OwnableUpgradeable, IMintableEditions) returns (address) {
        return super.owner();
    }

    /**
     * Allows the edition owner to set the amount of tokens (max 65535) an address is allowed to mint.
     * 
     * If the ZeroAddress (address(0x0)) is set as a minter with an allowance greater than 0, anyone will be allowed 
     * to mint any amount of tokens, similarly to setApprovalForAll in the ERC721 spec.
     * If the allowed amount is set to 0 then the address will NOT be allowed to mint.
     * 
     * @param minter address to set approved minting status for
     * @param allowed uint16 how many tokens this address is allowed to mint, 0 disables minting
     */
    function setApprovedMinter(address minter, uint16 allowed) public onlyOwner {
        allowedMinters[minter] = allowed;
    }

    /**
     * Allows for updates of edition urls by the owner of the edition.
     * Only URLs can be updated (data-uris are supported), hashes cannot be updated.
     */
    function updateEditionURL(string memory _contentUrl) public onlyOwner {
        contentUrl = _contentUrl;
    }

    /** 
     * Returns the number of tokens still available for minting (uint64 when open edition)
     */
    function numberCanMint() public view override returns (uint256) {
        // atEditionId is one-indexed hence the need to remove one here
        return size + 1 - counter.current();
    }

    /**
     * User burn function for token id.
     * 
     *  @param tokenId Token ID to burn
     */
    function burn(uint256 tokenId) public {
        require(_isApprovedOrOwner(_msgSender(), tokenId), "Not approved");
        _burn(tokenId);
    }

    /**
     * Private function to mint without any access checks.
     * Called by the public edition minting functions.
     */
    function _mintEditions(address[] memory recipients) internal returns (uint256) {
        uint64 startAt = uint64(counter.current());
        uint64 endAt = uint64(startAt + recipients.length - 1);
        require(size == 0 || endAt <= size, "Sold out");
        while (counter.current() <= endAt) {
            _mint(recipients[counter.current() - startAt], counter.current());
            counter.increment();
        }
        return counter.current();
    }

    /**
     * Get URI and hash for edition NFT
     * @return contentUrl, contentHash
     */
    function getURI() public view returns (string memory, bytes32) {
        return (contentUrl, contentHash);
    }

    /**
     * Get URI for given token id
     * 
     * @param tokenId token id to get uri for
     * @return base64-encoded json metadata object
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "No token");
        return metadata.createTokenURI(name(), description, contentUrl, contentType, tokenId, size);
    }
    
     /**
      * ERC2981 - Gets royalty information for token
      * @param _value the sale price for this token
      */
    function royaltyInfo(uint256, uint256 _value) external view override returns (address receiver, uint256 royaltyAmount) {
        if (owner() == address(0x0)) {
            return (owner(), 0);
        }
        return (owner(), (_value * royalties) / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, IERC165Upgradeable) returns (bool) {
        return type(IERC2981Upgradeable).interfaceId == interfaceId || ERC721Upgradeable.supportsInterface(interfaceId);
    }
}
