// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./libraries/TransferHelper.sol";

contract TribeOne is Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    // using SafeMath for uint256;

    enum Status {
        LISTED, // after the loan have been created --> the next status will be APPROVED
        APPROVED, // in this status the loan has a lender -- will be set after approveLoan(). loan fund => borrower
        DEFAULTED, // NFT was brough from opensea by agent and staked in TribeOne - relayNFT()
        FAILED, // NFT buying order was failed in partner's platform such as opensea...
        CANCELLED, // only if loan is LISTED - cancelLoan()
        WITHDRAWN // the final status, the collateral returned to the borrower or to the lender withdrawNFT()
    }
    enum TokenType {
        ERC721,
        ERC1155
    }

    mapping(address => bool) private WHITE_LIST;

    struct Loan {
        address[] nftAddressArray; // the adderess of the ERC721
        address borrower; // the address who receives the loan
        address currency; // the token that the borrower lends, address(0) for ETH
        Status status; // the loan status
        uint256[] nftTokenIdArray; // the unique identifier of the NFT token that the borrower uses as collateral
        uint256 loanAmount; // the amount, denominated in tokens (see next struct entry), the borrower lends
        uint256 amountDue; // loanAmount + interest that needs to be paid back by borrower
        uint256 paidAmount; // the amount that has been paid back to the lender to date
        uint256 installmentAmount; // amount expected for each installment
        uint256 assetsValue; // important for determintng LTV which has to be under 50-60%
        uint256 loanStart; // the point when the loan is approved
        uint256 loanEnd; // the point when the loan is approved to the point when it must be paid back to the lender
        uint256 nrOfInstallments; // the number of installments that the borrower must pay.
        uint256 defaultingLimit; // the number of installments allowed to be missed without getting defaulted
        uint256 nrOfPayments; // the number of installments paid
        TokenType[] nftTokenTypeArray; // the token types : ERC721 , ERC1155 , ...
    }

    // loanId => Loan
    mapping(uint256 => Loan) loans;
    Counters.Counter private loanIds;
    // Loan to value(ltv). 600=60%
    uint256 public constant LTV = 600;
    // 20 =20%
    uint256 public constant interestRate = 20;

    event NewLoan(
        uint256 indexed loanId,
        address indexed owner,
        uint256 creationDate,
        address indexed currency,
        Status status,
        address[] nftAddressArray,
        uint256[] nftTokenIdArray,
        TokenType[] nftTokenTypeArray
    );

    event LoanApproved(uint256 indexed _loanId, uint256 _to, uint256 _fundAmount);

    constructor() {}

    modifier onlyAgent() {
        require(WHITE_LIST[msg.sender], "TribeOne: Forbidden");
        _;
    }

    function addAgent(address _agent) external onlyOwner {
        WHITE_LIST[_agent] = true;
    }

    function createLoan(
        uint256 loanAmount,
        uint256 nrOfInstallments,
        address currency,
        uint256 assetsValue,
        address[] calldata nftAddressArray,
        uint256[] calldata nftTokenIdArray,
        TokenType[] memory nftTokenTypeArray
    ) external {
        require(nrOfInstallments > 0, "Loan must have at least 1 installment");
        require(loanAmount > 0, "Loan amount must be higher than 0");
        require(nftAddressArray.length > 0, "Loan must have atleast 1 NFT");
        require(
            nftAddressArray.length == nftTokenIdArray.length && nftTokenIdArray.length == nftTokenTypeArray.length,
            "NFT provided informations are missing or incomplete"
        );

        // TODO Validate currency

        uint256 loanID = loanIds.current();
        // Compute loan to value ratio for current loan application
        require(_percent(loanAmount, assetsValue) <= LTV, "LTV exceeds maximum limit allowed");

        // Computing the defaulting limit
        // if ( nrOfInstallments <= 3 )
        //     loans[loanID].defaultingLimit = 1;
        // else if ( nrOfInstallments <= 5 )
        //     loans[loanID].defaultingLimit = 2;
        // else if ( nrOfInstallments >= 6 )
        //     loans[loanID].defaultingLimit = 3;

        TransferHelper.safeTransferFrom(currency, _msgSender(), address(this), loanAmount);

        // Set loan fields
        loans[loanID].nftTokenIdArray = nftTokenIdArray;
        loans[loanID].loanAmount = loanAmount;
        loans[loanID].assetsValue = assetsValue;
        // loans[loanID].amountDue = loanAmount.mul(interestRate .add(100)).div(100); // interest rate >> 20%
        loans[loanID].amountDue = (loanAmount * (interestRate + 100)) / 100; // interest rate >> 20%
        loans[loanID].nrOfInstallments = nrOfInstallments;
        // loans[loanID].installmentAmount = loans[loanID].amountDue.mod(nrOfInstallments) > 0
        //     ? loans[loanID].amountDue.div(nrOfInstallments).add(1)
        //     : loans[loanID].amountDue.div(nrOfInstallments);
        loans[loanID].installmentAmount = loans[loanID].amountDue / nrOfInstallments > 0
            ? loans[loanID].amountDue / nrOfInstallments + 1
            : loans[loanID].amountDue / nrOfInstallments;
        loans[loanID].status = Status.LISTED;
        loans[loanID].nftAddressArray = nftAddressArray;
        loans[loanID].borrower = msg.sender;
        loans[loanID].currency = currency;
        loans[loanID].nftTokenTypeArray = nftTokenTypeArray;

        // Fire event
        emit NewLoan(
            loanID,
            msg.sender,
            block.timestamp,
            currency,
            Status.LISTED,
            nftAddressArray,
            nftTokenIdArray,
            nftTokenTypeArray
        );
        loanIds.increment();
    }

    /**
     * @dev _loandId: loandId, _token: currency of NFT, _amount: requested fund amount
     */
    function approveLoan(
        uint256 _loanId,
        address _token,
        uint256 _amount
    ) external onlyAgent nonReentrant {
        require(loans[_loanId].status == Status.LISTED, "TribeOne: Invalid request");
        loans[_loanId].status = Status.APPROVED;
        loans[_loanId].loanAmount += _amount;
        if (_token == address(0)) {
            TransferHelper.safeTransferETH(msg.sender, _amount);
        } else {
            TransferHelper.safeTransfer(_token, _msgSender(), _amount);
        }
    }

    function relayNFT(uint256 _loanId, bool _accepted) external onlyAgent nonReentrant {
        if (_accepted) {
            // Saving for gas
            Loan memory _loan = loans[_loanId];
            require(_loan.status == Status.APPROVED, "TribeOne: Not approved loan");

            uint256 len = _loan.nftAddressArray.length;
            for (uint256 ii = 0; ii < len; ii++) {
                address _nftAddress = _loan.nftAddressArray[ii];
                uint256 _tokenId = _loan.nftTokenIdArray[ii];

                // We assume only ERC721 case first
                // ERC721 case
                if (_loan.nftTokenTypeArray[ii] == TokenType.ERC721) {
                    IERC721(_nftAddress).approve(address(this), _tokenId);
                    IERC721(_nftAddress).safeTransferFrom(_msgSender(), address(this), _tokenId);
                }
                // TODO - ERC1155
            }

            loans[_loanId].status = Status.DEFAULTED;
        } else {
            loans[_loanId].status = Status.FAILED;
            returnColleteral(_loanId);
        }
    }

    /**
     * TODO ERC20 we should touch
     */
    function payInstallment(uint256 _loanId) external payable onlyAgent {
        // Just for saving gas
        Loan memory _loan = loans[_loanId];
        require(_loan.status == Status.DEFAULTED, "TribeOne: Not defaulted loan");
        require(msg.value <= _loan.amountDue - _loan.paidAmount, "TribeOne: Too much value");

        loans[_loanId].paidAmount += msg.value;
    }

    function withdrawNFT(uint256 _loanId) external nonReentrant {
        Loan memory _loan = loans[_loanId];
        require(_msgSender() == _loan.borrower, "TribeOne: Forbidden");
        require(_loan.paidAmount == _loan.amountDue, "TribeOne: Still debt");
        uint256 len = _loan.nftAddressArray.length;
        for (uint256 ii = 0; ii < len; ii++) {
            address _nftAddress = _loan.nftAddressArray[ii];
            uint256 _tokenId = _loan.nftTokenIdArray[ii];

            // We assume only ERC721 case first
            // ERC721 case
            if (_loan.nftTokenTypeArray[ii] == TokenType.ERC721) {
                IERC721(_nftAddress).safeTransferFrom(address(this), _msgSender(), _tokenId);
            }
            // TODO - ERC1155
        }

        loans[_loanId].status = Status.WITHDRAWN;

        returnColleteral(_loanId);
    }

    function cancelLoan(uint256 _loanId) external nonReentrant {
        Loan memory _loan = loans[_loanId];
        require(_loan.borrower == _msgSender() && _loan.status == Status.LISTED, "TribeOne: Forbidden");
        loans[_loanId].status = Status.CANCELLED;

        returnColleteral(_loanId);
    }

    function _percent(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        // return numerator.mul(10000).div(denominator).add(5).div(10);
        return ((numerator * 10000) / denominator + 5) / 10;
    }

    /**
     * @dev return back collateral to borrower due to some reasons
     * such as canceled order in opensea, or canncel loan, withdraw NFT
     */
    function returnColleteral(uint256 _loanId) private {
        Loan memory _loan = loans[_loanId];
        address _currency = _loan.currency;
        uint256 _amount = _loan.loanAmount;
        address _to = _loan.borrower;
        if (_currency == address(0)) {
            TransferHelper.safeTransferETH(_to, _amount);
        } else {
            TransferHelper.safeTransfer(_currency, _to, _amount);
        }
    }
}
