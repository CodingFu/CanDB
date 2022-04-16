// Simple Example for keeping track of transactions 

import CanDB "../../../src/CanDB";
import Entity "../../../src/Entity";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Int "mo:base/Int";
import Option "mo:base/Option";
import Text "mo:base/Text";
import Debug "mo:base/Debug";

/// Note: This is example is not meant to be used as is in a system handling assets of value. It does not include 
/// access control or any security measures, and is purely meant to showcase example usage of CanDB

/// This example shows how one might support a application that keeps track of balances and transactions with CanDB

/// First, define access patterns for the application
///
/// access patterns
/// 1. get current balance for a user 
/// 2. get user balance history (latest n transactions)
/// 3. get latest transactions overall
/// 4. get latest transactions by user
/// 
/// 2 different pk/sk combinations needed
/// 
/// PK                   SK                              Meets Access Patern(s)
/// 
/// user#[userId]        transaction#[transactionId]     (1, 2, 4)
/// transaction          transaction#[transactionId]     (3)
///
/// Then determine APIs needed to support those access patterns
///
/// - getCurrentUserBalance (access pattern 1)
/// - getUserBalanceHistory (access pattern 2)
/// - getLatestTransactions (access pattern 3)
/// - getLatestUserTransactions (access pattern 4)
/// - createUserDeposit
/// - createTransaction

actor {
  // Initialize CanDB
  stable let db = CanDB.init();

  // Time package does not work locally, so use incrementing transactionIdCounter as a unique 
  // identifier instead of using UUID/ULID (requires the Time package)
  stable var transactionIdCounter = 1;

  // APIs

  public type GetUserBalanceRequest = {
    userId: Text
  };

  public type GetUserBalanceResponse = {
    balance: ?Int;
  };

  // get the current balance of the user
  public func getCurrentUserBalance(request: GetUserBalanceRequest): async GetUserBalanceResponse {
    { balance = getCurrentBalanceForUser(request.userId); }
  };

  type GetUserBalanceHistoryRequest = GetUserTransactionHistoryRequest;

  type GetUserBalanceHistoryResponse = {
    balances: [Int];
    nextKey: ?Text;
  };

  // gets the user balance history
  public func getUserBalanceHistory(request: GetUserBalanceHistoryRequest): async GetUserBalanceHistoryResponse {
    let { transactions; nextKey } = getUserTransactionHistory(request);
    {
      balances = Array.map<UserTransactionResult, Int>(transactions, func(txn) { txn.currentBalance });
      nextKey = nextKey;
    }
  };

  type GetLatestTransactionsRequest = {
    limit: Nat;
    nextKey: ?Text;
  };

  type GetLatestTransactionsResponse = {
    transactions: [TransactionResult];
    nextKey: ?Text;
  };
  
  // get all latest transactions (regardless of the users involved)
  public func getLatestTransactions(request: GetLatestTransactionsRequest): async GetLatestTransactionsResponse {
    let upperBound = Option.get(request.nextKey, "transaction#:");
    let { entities; nextKey } = CanDB.scan(db, { 
      pk = "transaction"; 
      skLowerBound = "transaction#0";
      skUpperBound = upperBound; 
      limit = request.limit;
      // want latest transactions, so descending order
      ascending = ?false;
    });
    switch(entities.size()) {
      case 0 {{ transactions = []; nextKey = nextKey }};
      case _ {{ transactions = unwrapValidTransactions(entities); nextKey = nextKey; }}
    }
  };

  type GetLatestUserTransactionsRequest = {
    userId: Text;
    limit: Nat; // number of results per request (for pagination, result chunking)
    nextKey: ?Text; // transactionId key to start retrieving results from
  };

  type GetLatestUserTransactionResponse = UserTransactionHistoryResponse;

  // gets the latest transactions for a user
  public func getLatestUserTransactions(request: GetLatestUserTransactionsRequest): async GetLatestTransactionsResponse {
    let upperBound = Option.get(request.nextKey, "transaction#:");
    let { entities; nextKey } = CanDB.scan(db, { 
      pk = "user#" # request.userId; 
      skLowerBound = "transaction#0";
      skUpperBound = upperBound; 
      limit = request.limit;
      // want latest transactions, so descending order
      ascending = ?false;
    });
    switch(entities.size()) {
      case 0 {{ transactions = []; nextKey = nextKey; }};
      case _ {{ transactions = unwrapValidUserTransactions(entities); nextKey = nextKey; }}
    }
  };

  type CreateUserDepositRequest = {
    userId: Text;
    depositAmount: Int;
  };

  type CreateUserDepositResponse = {
    transactionId: Text;
    currentBalance: Int;
  };

  // deposits funds for a user
  public func createUserDeposit(request: CreateUserDepositRequest): async ?CreateUserDepositResponse {
    if (request.depositAmount <= 0) { return null }; 

    let balance = Option.get(getCurrentBalanceForUser(request.userId), 0);
    let newBalance = balance + request.depositAmount; 
    let transactionId = Int.toText(transactionIdCounter);

    // create a new transaction
    CanDB.put(db, {
      pk = "transaction";
      sk = "transaction#" # transactionId;
      attributes = [
        ("transactionType", #Text("deposit")),
        ("transactionId", #Text(transactionId)),
        ("transactionAmount", #Int(request.depositAmount)),
        ("previousBalance", #Int(balance)),
        ("currentBalance", #Int(newBalance)),
        ("receiverUserId", #Text(request.userId)),
        ("senderUserId", #Text("deposit")),
      ]
    });

    // create a new userTransaction
    CanDB.put(db, {
      pk = "user#" # request.userId;
      sk = "transaction#" # transactionId;
      attributes = [
        ("transactionType", #Text("deposit")),
        ("transactionId", #Text(transactionId)),
        ("transactionAmount", #Int(request.depositAmount)),
        ("previousBalance", #Int(balance)),
        ("currentBalance", #Int(newBalance)),
        ("receiverUserId", #Text(request.userId)),
        ("senderUserId", #Text("deposit")),
      ]
    });

    // deposits count as a transaction, so increment the counter
    transactionIdCounter += 1;

    ?{
      transactionId = transactionId;
      currentBalance = newBalance;
    }
  };

  type CreateTransactionRequest = {
    senderUserId: Text;
    receiverUserId: Text;
    transactionAmount: Int;
  };
  
  type CreateTransactionResponse = {
    transactionId: Text;
    transactionAmount: Int;
    senderUserId: Text;
    receiverUserId: Text;
  };

  // creates a transaction
  public func createTransaction(request: CreateTransactionRequest): async ?CreateTransactionResponse {
    let { senderUserId; receiverUserId; transactionAmount; } = request;
    let senderUserBalance = getCurrentBalanceForUser(senderUserId);
    let receiverUserBalance = getCurrentBalanceForUser(receiverUserId);
    switch((senderUserBalance, receiverUserBalance)) {
      case (null, _) { null };
      case (?senderBalance, _) {
        if (senderBalance <= transactionAmount) { return null };

        let receiverBalance = Option.get(receiverUserBalance, 0);
        let transactionId = Int.toText(transactionIdCounter);
        let updatedSenderBalance = senderBalance - transactionAmount;
        let updatedReceiverBalance = receiverBalance + transactionAmount;

        // Create transaction and user transaction entities in CanDB
        // Note: for all of the created entities below the time package does not work locally,
        // but one could easily include a timestamp attribute with (timestamp", Time.now())

        // create a new transaction
        CanDB.put(db, {
          pk = "transaction";
          sk = "transaction#" # transactionId;
          attributes = [
            ("transactionType", #Text("transfer")),
            ("transactionId", #Text(transactionId)),
            ("senderUserId", #Text(senderUserId)),
            ("receiverUserId", #Text(receiverUserId)),
            ("transactionAmount", #Int(transactionAmount)),
          ]
        });

        // create a new transaction for the sending user 
        CanDB.put(db, {
          pk = "user#" # senderUserId;
          sk = "transaction#" # transactionId;
          attributes = [
            ("transactionType", #Text("transfer")),
            ("transactionId", #Text(transactionId)),
            ("receiverUserId", #Text(receiverUserId)),
            ("senderUserId", #Text(senderUserId)),
            ("transactionAmount", #Int(Int.neq(transactionAmount))),
            ("previousBalance", #Int(senderBalance)),
            ("currentBalance", #Int(updatedSenderBalance)),
          ]
        });

        // create a new transaction for the receiving user
        CanDB.put(db, {
          pk = "user#" # receiverUserId;
          sk = "transaction#" # transactionId;
          attributes = [
            ("transactionType", #Text("transfer")),
            ("transactionId", #Text(transactionId)),
            ("receiverUserId", #Text(receiverUserId)),
            ("senderUserId", #Text(senderUserId)),
            ("transactionAmount", #Int(transactionAmount)),
            ("previousBalance", #Int(receiverBalance)),
            ("currentBalance", #Int(updatedReceiverBalance)),
          ]
        });

        // increment the transactionId
        transactionIdCounter += 1;

        return ?{
          transactionId = transactionId;
          transactionAmount = transactionAmount;
          senderUserId = senderUserId;
          receiverUserId = receiverUserId;
        };
      };
    }
  };

  // Helper functions

  func getCurrentBalanceForUser(userId: Text): ?Int {
    let { entities; nextKey } = CanDB.scan(db, { 
      pk = "user#" # userId; 
      skLowerBound = "transaction#0";
      skUpperBound = "transaction#:"; 
      limit = 1;
      // we want to scan in descending order since we want the balance from most recent transaction
      ascending = ?false;
    });
    if (entities.size() != 1) { return null };

    let mostRecentUserTransaction = entities[0]; 
    switch(Entity.getAttributeMapValueForKey(mostRecentUserTransaction.attributes, "currentBalance")) {
      case (?(#Int(currentBalance))) { ?currentBalance };
      case _ { null };
    }
  };
  
  type UserTransactionResult = {
    transactionId: Text;
    transactionAmount: Int;
    currentBalance: Int;
    senderUserId: Text;
    receiverUserId: Text;
  };

  type UserTransactionHistoryResponse = {
    transactions: [UserTransactionResult];
    nextKey: ?Entity.SK;
  };

  type GetUserTransactionHistoryRequest = {
    userId: Text;
    limit: Nat; // number of results per request (for pagination, result chunking)
    ascending: ?Bool; // in ascending or desending order (defaults to ascending)
    nextKey: ?Text; // transactionId key to start retrieving results from
  };

  func getUserTransactionHistory(request: GetUserTransactionHistoryRequest): UserTransactionHistoryResponse {
    var lowerBound = "transaction#0";
    var upperBound = "transaction#:";
    switch(request.nextKey, request.ascending) {
      case (null, _) {};
      case (?sk, ?false) { upperBound := sk };
      case (?sk, _) { lowerBound := sk };
    };
    let { entities; nextKey } = CanDB.scan(db, { 
      pk = "user#" # request.userId; 
      skLowerBound = lowerBound;
      skUpperBound = upperBound; 
      limit = request.limit;
      ascending = request.ascending;
    });
    switch(entities.size()) {
      case 0 {{ transactions = []; nextKey = nextKey; }};
      case _ {{ transactions = unwrapValidUserTransactions(entities); nextKey = nextKey; }}
    }
  };

  func unwrapValidUserTransactions(entities: [Entity.Entity]): [UserTransactionResult] {
    Array.mapFilter<Entity.Entity, UserTransactionResult>(entities, func(e) {
      let { sk; attributes; } = e;
      let transactionId = Iter.toArray(Text.split(sk, #text("#")))[1];
      let transactionAmount = Entity.getAttributeMapValueForKey(attributes, "transactionAmount");
      let currentBalance = Entity.getAttributeMapValueForKey(attributes, "currentBalance");
      let senderUserId = Entity.getAttributeMapValueForKey(attributes, "senderUserId");
      let receiverUserId = Entity.getAttributeMapValueForKey(attributes, "receiverUserId");
      switch(transactionAmount, currentBalance, senderUserId, receiverUserId) {
        case (
          ?(#Int(transactionAmount)),
          ?(#Int(currentBalance)),
          ?(#Text(senderUserId)),
          ?(#Text(receiverUserId)) 
        ) {
          ?{
            transactionId = transactionId;
            transactionAmount = transactionAmount;
            currentBalance = currentBalance;
            senderUserId = senderUserId;
            receiverUserId = receiverUserId;
          }
        };
        case _ { 
          Debug.print("invalid user transaction");
          null
        }
      }
    })
  };

  type TransactionResult = {
    transactionId: Text;
    transactionAmount: Int;
    senderUserId: Text;
    receiverUserId: Text;
  };

  func unwrapValidTransactions(entities: [Entity.Entity]): [TransactionResult] {
    Array.mapFilter<Entity.Entity, TransactionResult>(entities, func(e) {
      let { sk; attributes; } = e;
      let transactionId = Iter.toArray(Text.split(sk, #text("#")))[1];
      let transactionAmountValue = Entity.getAttributeMapValueForKey(attributes, "transactionAmount");
      let senderUserIdValue = Entity.getAttributeMapValueForKey(attributes, "senderUserId");
      let receiverUserIdValue = Entity.getAttributeMapValueForKey(attributes, "receiverUserId");
      switch(transactionAmountValue, senderUserIdValue, receiverUserIdValue) {
        case (
          ?(#Int(transactionAmount)),
          ?(#Text(senderUserId)),
          ?(#Text(receiverUserId)) 
        ) {
          ?{
            transactionId = transactionId;
            transactionAmount = transactionAmount;
            senderUserId = senderUserId;
            receiverUserId = receiverUserId;
          }
        };
        case _ { 
          Debug.print("invalid transaction");
          null
        }
      }
    })
  };
}