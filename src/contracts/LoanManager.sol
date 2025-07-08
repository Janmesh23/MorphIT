// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// import "@openzeppelin/contracts/access/Ownable.sol";
// import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MeshUSD.sol";

contract LoanManager is ReentrancyGuard {
    MeshUSD public meshUSD;
    
    struct Loan {
        address borrower;
        address lender;
        uint256 amount;
        uint256 interestRate; // basis points (e.g., 500 = 5%)
        uint256 dueDate;
        bool funded;
        bool repaid;
        bool defaulted;
    }

    mapping(uint256 => Loan) public loans;
    mapping(address => uint256[]) public borrowerLoans;
    mapping(address => uint256[]) public lenderLoans;
    
    uint256 public loanCounter;
    uint256 public constant MAX_INTEREST_RATE = 5000; // 50% max
    uint256 public constant MIN_LOAN_DURATION = 1 days;
    uint256 public constant MAX_LOAN_DURATION = 365 days;

    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanFunded(uint256 indexed loanId, address indexed lender);
    event LoanRepaid(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId);

    constructor(address _meshUSD) {
        meshUSD = MeshUSD(_meshUSD);
    }

    function requestLoan(
        uint256 amount,
        uint256 duration,
        uint256 interestRate
    ) external returns (uint256 loanId) {
        require(amount > 0, "Loan amount must be greater than 0");
        require(duration >= MIN_LOAN_DURATION && duration <= MAX_LOAN_DURATION, "Invalid duration");
        require(interestRate <= MAX_INTEREST_RATE, "Interest rate too high");
        
        loanId = loanCounter++;
        loans[loanId] = Loan({
            borrower: msg.sender,
            lender: address(0),
            amount: amount,
            interestRate: interestRate,
            dueDate: block.timestamp + duration,
            funded: false,
            repaid: false,
            defaulted: false
        });
        
        borrowerLoans[msg.sender].push(loanId);
        emit LoanRequested(loanId, msg.sender, amount);
    }

    function fundLoan(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        require(!loan.funded, "Loan already funded");
        require(loan.borrower != msg.sender, "Cannot fund own loan");
        require(block.timestamp < loan.dueDate, "Loan expired");
        
        require(meshUSD.transferFrom(msg.sender, loan.borrower, loan.amount), "Transfer failed");
        
        loan.lender = msg.sender;
        loan.funded = true;
        lenderLoans[msg.sender].push(loanId);
        
        emit LoanFunded(loanId, msg.sender);
    }

    function repayLoan(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        require(msg.sender == loan.borrower, "Not the borrower");
        require(loan.funded, "Loan not funded");
        require(!loan.repaid, "Already repaid");
        require(!loan.defaulted, "Loan defaulted");
        
        uint256 repaymentAmount = loan.amount + (loan.amount * loan.interestRate) / 10000;
        require(meshUSD.transferFrom(msg.sender, loan.lender, repaymentAmount), "Repayment failed");
        
        loan.repaid = true;
        emit LoanRepaid(loanId);
    }

    function markDefault(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(loan.funded, "Loan not funded");
        require(!loan.repaid, "Already repaid");
        require(!loan.defaulted, "Already defaulted");
        require(block.timestamp > loan.dueDate, "Loan not due yet");
        require(msg.sender == loan.lender, "Only lender can mark default");
        
        loan.defaulted = true;
        emit LoanDefaulted(loanId);
    }

    function getBorrowerLoans(address borrower) external view returns (uint256[] memory) {
        return borrowerLoans[borrower];
    }

    function getLenderLoans(address lender) external view returns (uint256[] memory) {
        return lenderLoans[lender];
    }
}
