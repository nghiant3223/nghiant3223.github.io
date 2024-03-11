---
title: "Deadlock In MySQL"
date: 2024-03-09
---

# Deadlock In MySQL

## Introduction

Deadlocks in MySQL can be a significant challenge for database administrators and developers alike. A deadlock occurs when two or more transactions are each waiting for a resource locked by the other, resulting in a circular waiting pattern that halts progress. Understanding how deadlocks happen, their implications, and strategies to mitigate them is crucial for maintaining the stability and performance of MySQL databases.

In this blog, we will delve into the intricacies of deadlocks in MySQL. We will explore common scenarios that lead to deadlocks, discuss the impact they can have on application performance, and provide practical approaches to prevent and manage them effectively. 

## Demonstration

To illustrate the occurrence and resolution of deadlocks in MySQL, let's walk through a practical demonstration. In this scenario, we'll create a simple database schema and perform transactions that can potentially lead to deadlocks. We'll then analyze the deadlock situation and implement strategies to mitigate and resolve it.

Please note that the demonstration below is conducted using MySQL 8.0.32.

## Preparation

```sql
CREATE SCHEMA IF NOT EXISTS `deadlock_playground`;

USE `deadlock_playground`;

CREATE TABLE `t`
(
    `id` INT NOT NULL AUTO_INCREMENT,
    `a`  INT,
    `b`  INT,
    PRIMARY KEY (`id`),
    UNIQUE INDEX uq_a (`a`)
);

INSERT INTO `t` (a, b) VALUES (10, 10), (20, 20), (30, 30), (40, 40), (50, 50);
```

## Scenario 1: Insert The Same Primary Key

Different sessions attempting to `INSERT` records with the same primary key at the same time can cause deadlock at every isolation level. This also applies to the `INSERT ... ON DUPLICATE KEY ...` statement.

Below is an example results in deadlock, in which isolation level SERIALIZABLE is used.

| Timestamp | Session 1                                                                               | Session 2                                                                               | Session 3                                                                               |
|-----------|-----------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| T1        | SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;<br/><br/>START TRANSACTION;<br/>// transaction ID 1934<br/><br/>INSERT INTO t(id,a,b) VALUES (45,45,1) ON DUPLICATE KEY UPDATE b=-1; |                                                                                         |                                                                                         |
| T2        |                                                                                         | SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;<br/><br/>START TRANSACTION;<br/>// transaction ID 1935<br/><br/>INSERT INTO t(id,a,b) VALUES (45,45,2) ON DUPLICATE KEY UPDATE b=-1; |                                                                                         |
| T3        |                                                                                         |                                                                                         | SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;<br/><br/>START TRANSACTION;<br/>// transaction ID 1936<br/><br/>INSERT INTO t(id,a,b) VALUES (45,45,3) ON DUPLICATE KEY UPDATE b=-1; |
| T4        | ROLLBACK;                                                                               |                                                                                         |                                                                                         |
| T5        |                                                                                         | 1 rows affected                                                                        | Deadlock found when trying to get lock; try restarting transaction                      |

After T3, lock data are as below:
```
mysql> SELECT ENGINE_TRANSACTION_ID, INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA FROM performance_schema.data_locks WHERE OBJECT_NAME='t';
+-----------------------+------------+-----------+---------------+-------------+-----------+
| ENGINE_TRANSACTION_ID | INDEX_NAME | LOCK_TYPE | LOCK_MODE     | LOCK_STATUS | LOCK_DATA |
+-----------------------+------------+-----------+---------------+-------------+-----------+
|                  1936 | NULL       | TABLE     | IX            | GRANTED     | NULL      |
|                  1936 | PRIMARY    | RECORD    | X,REC_NOT_GAP | WAITING     | 45        |
|                  1935 | NULL       | TABLE     | IX            | GRANTED     | NULL      |
|                  1935 | PRIMARY    | RECORD    | X,REC_NOT_GAP | WAITING     | 45        |
|                  1934 | NULL       | TABLE     | IX            | GRANTED     | NULL      |
|                  1934 | PRIMARY    | RECORD    | X,REC_NOT_GAP | GRANTED     | 45        |
+-----------------------+------------+-----------+---------------+-------------+-----------+
```

After T4, lock data are as below:
```
mysql> SELECT ENGINE_TRANSACTION_ID, INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA FROM performance_schema.data_locks WHERE OBJECT_NAME='t';
+-----------------------+------------+-----------+------------------------+-------------+-----------+
| ENGINE_TRANSACTION_ID | INDEX_NAME | LOCK_TYPE | LOCK_MODE              | LOCK_STATUS | LOCK_DATA |
+-----------------------+------------+-----------+------------------------+-------------+-----------+
|                  1935 | NULL       | TABLE     | IX                     | GRANTED     | NULL      |
|                  1935 | PRIMARY    | RECORD    | X,GAP                  | GRANTED     | 45        |
|                  1935 | PRIMARY    | RECORD    | X,GAP                  | GRANTED     | 50        |
|                  1935 | PRIMARY    | RECORD    | X,GAP,INSERT_INTENTION | GRANTED     | 50        |
+-----------------------+------------+-----------+------------------------+-------------+-----------+
```


After T4, deadlock information are as below:
```
------------------------
LATEST DETECTED DEADLOCK
------------------------
2024-03-09 10:11:14 281472264068992
*** (1) TRANSACTION:
TRANSACTION 1935, ACTIVE 16 sec inserting
mysql tables in use 1, locked 1
LOCK WAIT 4 lock struct(s), heap size 1128, 2 row lock(s)
MySQL thread id 20, OS thread handle 281472569147264, query id 2771 192.168.214.1 root update
/* ApplicationName=GoLand 2023.1.1 */ INSERT INTO `t`(id, `a`, `b`) VALUES (45,45,2) ON DUPLICATE KEY UPDATE `b` = -1

*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 2 page no 4 n bits 80 index PRIMARY of table `deadlock_playground`.`t` trx id 1935 lock_mode X locks gap before rec
Record lock, heap no 7 PHYSICAL RECORD: n_fields 5; compact format; info bits 0
 0: len 4; hex 80000032; asc    2;;
 1: len 6; hex 00000000076f; asc      o;;
 2: len 7; hex 810000009a012a; asc       *;;
 3: len 4; hex 80000032; asc    2;;
 4: len 4; hex 80000032; asc    2;;


*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 2 page no 4 n bits 80 index PRIMARY of table `deadlock_playground`.`t` trx id 1935 lock_mode X locks gap before rec insert intention waiting
Record lock, heap no 7 PHYSICAL RECORD: n_fields 5; compact format; info bits 0
 0: len 4; hex 80000032; asc    2;;
 1: len 6; hex 00000000076f; asc      o;;
 2: len 7; hex 810000009a012a; asc       *;;
 3: len 4; hex 80000032; asc    2;;
 4: len 4; hex 80000032; asc    2;;


*** (2) TRANSACTION:
TRANSACTION 1936, ACTIVE 4 sec inserting
mysql tables in use 1, locked 1
LOCK WAIT 4 lock struct(s), heap size 1128, 2 row lock(s)
MySQL thread id 22, OS thread handle 281472568090496, query id 2802 192.168.214.1 root update
/* ApplicationName=GoLand 2023.1.1 */ INSERT INTO `t`(id, `a`, `b`) VALUES (45,45,3) ON DUPLICATE KEY UPDATE `b` = -1

*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 2 page no 4 n bits 80 index PRIMARY of table `deadlock_playground`.`t` trx id 1936 lock_mode X locks gap before rec
Record lock, heap no 7 PHYSICAL RECORD: n_fields 5; compact format; info bits 0
 0: len 4; hex 80000032; asc    2;;
 1: len 6; hex 00000000076f; asc      o;;
 2: len 7; hex 810000009a012a; asc       *;;
 3: len 4; hex 80000032; asc    2;;
 4: len 4; hex 80000032; asc    2;;


*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 2 page no 4 n bits 80 index PRIMARY of table `deadlock_playground`.`t` trx id 1936 lock_mode X locks gap before rec insert intention waiting
Record lock, heap no 7 PHYSICAL RECORD: n_fields 5; compact format; info bits 0
 0: len 4; hex 80000032; asc    2;;
 1: len 6; hex 00000000076f; asc      o;;
 2: len 7; hex 810000009a012a; asc       *;;
 3: len 4; hex 80000032; asc    2;;
 4: len 4; hex 80000032; asc    2;;

*** WE ROLL BACK TRANSACTION (2)
```

One may ask, "Why does deadlock happen even for the highest isolation level, i.e., SERIALIZABLE?".

Let's refer to the MySQL [documentation](https://dev.mysql.com/doc/refman/8.0/en/innodb-transaction-isolation-levels.html#:~:text=READ%20COMMITTED.-,SERIALIZABLE,-This%20level%20is):
> SERIALIZABLE: This level is like REPEATABLE READ, but InnoDB implicitly converts all plain SELECT statements to SELECT ... FOR SHARE if autocommit is disabled. If autocommit is enabled, the SELECT is its own transaction. It therefore is known to be read-only and can be serialized if performed as a consistent (nonlocking) read and need not block for other transactions.

We can see that the SERIALIZABLE isolation level has nothing to do with the INSERT statement. Therefore, deadlock can definitely happen in the SERIALIZABLE isolation level.

## References

- https://cloud.tencent.com/developer/article/2326843