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

import {EditionMetadata} from "./EditionMetadata.sol";
import {IEdition} from "./IEdition.sol";
import {IRoyalties} from "./IRoyalties.sol";

/**
 * This contract allows dynamic NFT minting.
 * 
 * Operations allow for selling publicly, partial or total giveaways, direct giveaways and rewardings.
 */
contract Edition is ERC721Upgradeable, IERC2981Upgradeable, IEdition, OwnableUpgradeable {
    
    using CountersUpgradeable for CountersUpgradeable.Counter;
    event PriceChanged(uint256 amount);
    event EditionSold(uint256 price, address owner);

    // token description
    string private description;

    // token content URL
    string private contentUrl;
    // hash for the associated content
    bytes32 private contentHash;
    // type of content
    uint8 contentType;
    
    // Royalties ERC2981
    address royalties;

    // total size of tokens this edition can generate
    uint64 public editionSize;
    
    // address receiving the withdraw payment
    address payable private payee;

    // token id counter
    CountersUpgradeable.Counter private counter;
    
    // NFT rendering logic
    EditionMetadata private immutable metadata;

    // addresses allowed to mint edition
    mapping(address => uint16) allowedMinters;

    // price for sale
    uint256 public salePrice;

    constructor(EditionMetadata _metadata) {
        metadata = _metadata;
    }

    /**
     * Creates a new edition and sets the only allowed minter to the address that creates/owns the edition: this can be re-assigned or updated later.
     * 
     * @param _owner address of the edition creator: can authorize, mint, gets royalties and sales payouts, can update the content URL.
     * @param _name name of edition, used in the title as "$name $tokenId/$editionSize"
     * @param _symbol symbol of the new token contract
     * @param _description description of edition, used in the description field of the NFT
     * @param _contentUrl content URL of the edition
     * @param _contentHash SHA256 of the given content in bytes32 format (0xHASH)
     * @param _contentType type of content [0=image, 1=animation/video/audio]
     * @param _editionSize number of NFTs that can be minted from this edition: set to 0 for an unbound edition
     * @param _royalties royalties paid to the creator upon token selling
     * @param _payee address receiving the contract balance upon withdrawal
     */
    function initialize(
        address _owner,
        string memory _name,
        string memory _symbol,
        string memory _description,
        string memory _contentUrl,
        bytes32 _contentHash,
        uint8 _contentType,
        uint64 _editionSize,
        address _royalties,
        address payable _payee
    ) public initializer {
        require(AddressUpgradeable.isContract(_royalties), "Royalties address not a contract");
        __ERC721_init(_name, _symbol);
        __Ownable_init();
        // set ownership
        transferOwnership(_owner);
        description = _description;
        contentUrl = _contentUrl;
        contentHash = _contentHash;
        contentType = _contentType;
        editionSize = _editionSize;
        royalties = _royalties;
        if (_payee == address(0x0)) {
            payee = payable(_owner);
        } else {
            payee = _payee;
        }
        // edition start id is 1
        counter.increment();
    }


    /**
     * Returns the number of tokens minted within this edition 
     */
     function totalSupply() public view returns (uint256) {
        return counter.current() - 1;
    }

    /**
     * Basic ETH-based sales operation, performed at the given set price.
     * This operation is open to everyone as soon as the salePrice is set to a non-zero value.
     */
    function purchase() external payable returns (uint256) {
        require(salePrice > 0, "Not for sale");
        require(msg.value == salePrice, "Wrong price");
        address[] memory toMint = new address[](1);
        toMint[0] = msg.sender;
        emit EditionSold(salePrice, msg.sender);
        return _mintEditions(toMint);
    }

    /**
     * This operation sets the sale price, thus allowing anyone to acquire a token from this edition at the sale price via the purchase operation.
     * Setting the sale price to 0 prevents purchase of the tokens which is then allowed only to permitted addresses.
     * 
     * @param _wei if sale price is 0, no sale is allowed, otherwise the provided amount of WEI is needed to start the sale.
     */
    function setSalePrice(uint256 _wei) external onlyOwner {
        salePrice = _wei;
        emit PriceChanged(salePrice);
    }

    /**
     * This operation transfers all ETHs from the edition to the payee.
     */
    function withdraw() external {
        AddressUpgradeable.sendValue(payable(payee), address(this).balance);
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
    function owner() public view override(OwnableUpgradeable, IEdition) returns (address) {
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
        return editionSize + 1 - counter.current();
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
        require(editionSize == 0 || endAt <= editionSize, "Sold out");
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
        return metadata.createTokenURI(name(), description, contentUrl, contentType, tokenId, editionSize);
    }
    
     /**
      * ERC2981 - Gets royalty information for token
      * @param _salePrice the sale price for this token
      */
    function royaltyInfo(uint256 _tokenId, uint256 _salePrice) external view override returns (address receiver, uint256 royaltyAmount) {
        if (owner() == address(0x0) || royalties == address(0x0)) {
            return (address(0x0), 0);
        }
        return IRoyalties(royalties).royaltyInfo(_tokenId, _salePrice);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, IERC165Upgradeable) returns (bool) {
        return type(IERC2981Upgradeable).interfaceId == interfaceId || ERC721Upgradeable.supportsInterface(interfaceId);
    }
}
