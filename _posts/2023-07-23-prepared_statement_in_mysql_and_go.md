---
title: "Prepared Statement in MySQL and Go"
date: 2023-07-23
---

# Prepared Statement in MySQL and Go

# What is Prepared Statement?

In a database management system (DBMS) like MySQL, a prepared statement is a mechanism in which the DBMS server precompiles the SQL statement separately from the data, stores the compiled result, and later applies the data to the compiled result to get final result.

In DBMS, a prepared statement offers several benefits:

- Security: Prepared statements are resistant to SQL injection attacks. By separating the SQL statement from the data and handling them as separate entities, prepared statements provide an extra layer of security. This helps prevent malicious users from manipulating the SQL code by injecting malicious commands or unauthorized data into the query.
- Efficiency: Prepared statements avoid the need for repetitive recompilation of the SQL statement. When a prepared statement is executed multiple times, the DBMS server only needs to compile the SQL statement once. Subsequent executions of the prepared statement can reuse the compiled result, resulting in improved performance and reduced overhead.
- Convenience: Prepared statements are data type agnostic. This means that the data passed to the prepared statement does not require explicit data type conversions or validations. The DBMS automatically handles the data binding process, ensuring compatibility between the data and the SQL statement. This convenience simplifies the programming process and reduces the risk of errors related to data type mismatches.

Working with prepared statements is relatively straightforward. To utilize a prepared statement, you send the statement to the server, which includes placeholders (`?` in MySQL, `$1` in PostgreSQL, `:col` in Oracle) for the values you want to provide. Once you have sent the prepared statement to the server, you can request the database to execute the statement, providing the necessary arguments. These arguments correspond to the placeholders in the prepared statement and are typically passed as parameters to the execution command.

Although a prepared statement might seem as simple as telling a joke, if we're not careful, unexpected incidents could turn it into a comedy of errors. Let’s see how the incident occurred.

# Using Prepared Statement the Wrong Way

Presented below is the block of code from company X that has recently encountered an incident related to a prepared statement. To respect the non-disclosure agreement, I have made some modifications to the code while preserving its core idea.

```go
// newDB returns an instance of connection pool.
func newDB() (*sql.DB, error) {
	db, err := sql.Open("mysql", "root:password@tcp(127.0.0.1:3306)/demo?charset=utf8mb4&parseTime=True")
	if err != nil {
		return nil, err
	}

	db.SetMaxOpenConns(10)
	return db, nil
}

// findUsers returns a list of user whose id in `userIDs` input.
func findUsers(db *sql.DB, userIDs []int) ([]*User, error) {
  if len(userIDs) == 0 {
    return []*User{}, nil
  }

	argUserIDs := make([]interface{}, len(userIDs))
	for i, id := range userIDs {
		argUserIDs[i] = id
	}

	var placeholders string
	for i := 0; i < len(userIDs); i++ {
		placeholders += "?"
		if i != len(userIDs)-1 {
			placeholders += ","
		}
	}

	query := fmt.Sprintf("SELECT * FROM users WHERE id IN (%s)", placeholders)
	stmt, err := db.Prepare(query)
	if err != nil {
		return nil, err
	}

	rows, err := stmt.Query(argUserIDs...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []*User
	for rows.Next() {
		var user User
		if err := rows.Scan(&user.ID, &user.Username, &user.Age); err != nil {
			return nil, err
		}
		users = append(users, &user)
	}
	return users, nil
}
```

When the incident occurred, the system continuously logged the following error message: `Error - 1461: Can't create more than max_prepared_stmt_count statements (current value: 16382)`. As a result of this error, every `CREATE`, `SELECT`, `UPDATE`, and `DELETE` command failed with the error mentioned earlier, rendering the service unavailable for several hours.

Just to provide you with some background information, MySQL incorporates a system variable known as `[max_prepared_stmt_count](https://dev.mysql.com/doc/refman/5.7/en/server-system-variables.html#sysvar_max_prepared_stmt_count)`. This variable establishes a threshold for the maximum number of prepared statements permitted on the server, encompassing all connections. If the limit is reached and the client persists in requesting the server to prepare additional statements, the server will issue an error message: `Error 1461: Can't create more than max_prepared_stmt_count statements (current value: ...)`. Notably, the default value assigned to this variable is 16382, as indicated in the previously mentioned error message.

But why did the incident take place? Let's examine the function `findUsers` more closely. In `findUsers`, different value placeholders are created for varying lengths of `userIDs`, causing the database to generate distinct prepared statements. The error mentioned above occurs when there are more than 16382 unique prepared statements.

So, is the prepared statement solely responsible for the incident? I don’t think so. Before drawing any conclusions, it's wise to understand how prepared statements function.

# Understanding Prepared Statement

When a client submits a SQL statement containing parameter placeholders and their corresponding arguments, several message exchanges take place behind the scenes:

1. The client sends a SQL statement with placeholders to the server for preparation.
2. The server prepares (compiles) the statement and responses the client with a statement ID.
3. The client sends the statement ID along with the corresponding arguments to the server.
4. The server executes the statement and responses the client with a result.
5. The clients can **optionally** request the server to deallocate the prepared statement.

As you can see, there are two additional roundtrips (step 3 + step 4, and step 5) compared to the case where a prepared statement is not applied. To achieve both security, convenience and efficiency (efficiency the right way 😄), you have to sacrifice additional roundtrips.

In Go, there are at least 3 different approaches to work with SQL prepared statements:

- **Explicit prepared statement** and **implicit prepared statement** ******using [standard library](https://github.com/golang/go/tree/master/src/database/sql)
- **Implicit prepared statement** using [GORM](https://gorm.io/)

## Explicit Prepared Statement in Standard Library

**TL;DR**: The client uses `db.Prepare` to request the server to prepare a statement, sending the [COM_STMT_PREPARE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_prepare.html) command. In response, the server provides a statement ID. Subsequently, the client employs `stmt.QueryRow` to send the [COM_STMT_EXECUTE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_execute.html) command, requesting the server to execute the statement. Lastly, the client uses `stmt.Close` to send the [COM_STMT_CLOSE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_close.html) command, asking the server to close the prepared statement.

This is an code snippet that describes how you can use explicit prepared statement:

```go
1   db, err := sql.Open("mysql", "mysql://user:pass@localhost:3306/dbname")
2   if err != nil {
3     log.Fatal(err)
4   }
5
6   stmt, err := db.Prepare("SELECT * FROM album WHERE id = ?")
7   if err != nil {
8	   log.Fatal(err)
9   }
10  defer stmt.Close()
11 
12  var album Album
13  rows,err := stmt.QueryRow(id).Scan(&album.ID, &album.Title, &album.Artist)
14  if err != nil {
14    log.Fatal(err)
15  }
16  defer rows.Close()
```

In [Figure 1](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), the method `Prepare` at line 6 tells server to prepare the statement `SELECT * FROM album WHERE id = ?`. Internally, `db.Prepare` will eventually invokes the method `Prepare` of `*mysqlConn` in [Figure 2](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21).

```go
1  func (mc *mysqlConn) Prepare(query string) (driver.Stmt, error) {
2    ...
3    // Send command
4    err := mc.writeCommandPacketStr(comStmtPrepare, query)
5    ...
6    // Read result
7    columnCount, err := stmt.readPrepareResultPacket()
8    ...
9  }
```

Let’s analyze [Figure 2](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21). In this figure, we can see that at line 4, the method `writeCommandPacketStr` sends command [COM_STMT_PREPARE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_prepare.html) to the server. Then, at line 7, the client reads the [COM_STMT_PREPARE response](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_prepare.html#sect_protocol_com_stmt_prepare_response) to extract the statement ID that server has prepared and saves it to the variable `stmt` (more details can be found [here](https://github.com/go-sql-driver/mysql/blob/v1.7.1/packets.go#L838)).

Back to [Figure 1](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), the client sends statement ID along with corresponding arguments to the server by `stmt.QueryRow(id)`. Note that the parameter `id` here is the ID of the `Album` in question, not the statement ID. Internally, `QueryRow` will eventually invoke the method `query` of `*mysqlStmt` as in [Figure 3](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21). The method `writeExecutePacket` sends command [COM_STMT_EXECUTE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_execute.html) to the server. This command instructs the server to execute a prepared statement based on the statement ID provided. After that, in the method `readResultSetHeaderPacket`, the clients read the [COM_STMT_EXECUTE response](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_execute_response.html) to extract the result set and convert it to an instance of `binaryRows`. 

```go
 1  func (stmt *mysqlStmt) query(args []driver.Value) (*binaryRows, error) {
 2    ...
 3    // Send command
 4    err := stmt.writeExecutePacket(args)
 5    if err != nil {
 6      return nil, stmt.mc.markBadConn(err)
 7    }
 8    ...
 9    // Read result
10    resLen, err := mc.readResultSetHeaderPacket()
11    if err != nil {
12      return nil, err
13    }
14    ...
15    if resLen > 0 {
16      ...
17      rows.rs.columns, err = mc.readColumns(resLen)
18    } else {
19      ...
20    }
21    ...
22  }
```

The `Scan` method in [Figure 1](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21) will use this instance to scan an instance of `Album`. At the end of [Figure 1](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), `rows.Close()` is called, which will invoke the method `Close` of `*myStmt` as [Figure 4](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21). In the method `writeCommandPacketUint32`, the client sends command [COM_STMT_CLOSE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_close.html) to the server to make the prepared statement deallocated, ensuring no memory leak occurs.

```go
1  func (stmt *mysqlStmt) Close() error {
2    ...
3    err := stmt.mc.writeCommandPacketUint32(comStmtClose, stmt.id)
4    ...
5  }
```

## Implicit Prepared Statement in Standard Library

**TL;DR**: The client utilizes `db.Query` to send the [COM_STMT_PREPARE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_prepare.html) and [COM_STMT_EXECUTE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_execute.html) commands to the server, requesting it to prepare and execute a statement. Finally, the client employs `stmt.Close` to send the [COM_STMT_CLOSE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_close.html) command to the server, asking it to close the prepared statement. If the `[InterpolateParams](https://github.com/go-sql-driver/mysql#interpolateparams)` configuration is enabled, the client will send command [COM_QUERY](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html) and let the server execute the statement filled with interpolated arguments instead of using a prepared statement.

Working with implicit prepared statement is easier by passing prepared statement arguments (`id` in [Figure 5](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21)) to `db.Query` apart from the SQL statement as first argument. If there is no prepared statement argument, the client sends a non-prepared statement to the database server (i.e. the client sends command [COM_QUERY](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html) instead of [COM_STMT_PREPARE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_prepare.html) to the server).

```go
 1   db, err := sql.Open("mysql", "mysql://user:pass@localhost:3306/dbname")
 2   if err != nil {
 3     log.Fatal(err)
 4   }
 5 
 6   rows, err := db.Query("SELECT * FROM album WHERE id = ?", id)
 7   if err != nil {
 8     log.Fatal(err)
 9   }
10   defer rows.Close()
11  
12   var album Album
13   err = rows.Scan(&album.ID, &album.Title, &album.Artist)
14   if err != nil {
15     log.Fatal(err)
16   }
```

Line 6 in [Figure 5](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21) tells the server to prepare the statement `SELECT * FROM album WHERE id = ?` and executes the statement with the argument `id`. All of those things happen in the method `db.Query`. Internally, `db.Query` invokes the method `queryDC`, which is described in [Figure 6](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21).

```go
 1  func (db *DB) queryDC(ctx, txctx context.Context, dc *driverConn, releaseConn func(error), query string, args []any) (*Rows, error) {
 2    ...
 3    withLock(dc, func() {
 4      nvdargs, err = driverArgsConnLocked(dc.ci, nil, args)
 5      if err != nil {
 6        return
 7      }
 8      rowsi, err = ctxDriverQuery(ctx, queryerCtx, queryer, query, nvdargs)
 9    })
10    if err != driver.ErrSkip {
11      if err != nil {
12        releaseConn(err)
13        return nil, err
14      }
15      ...
16      return rows, nil
17    }
18    ...
19    withLock(dc, func() {
20      si, err = ctxDriverPrepare(ctx, dc.ci, query)
21    })
22    ...
23    ds := &driverStmt{Locker: dc, si: si}
24    rowsi, err := rowsiFromStatement(ctx, dc.ci, ds, args...)
25    if err != nil {
26      ds.Close()
27      releaseConn(err)
28      return nil, err
29    }
30    ...
31    rows := &Rows{
32      dc:          dc,
33      releaseConn: releaseConn,
34      rowsi:       rowsi,
35      closeStmt:   ds,
36    }
37    rows.initContextClose(ctx, txctx)
38    return rows, nil
39  }
```

In [Figure 6](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), `ctxDriverQuery` will invokes method `query` of `*mysqlConn` in [Figure 7](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21). In the `query` method, the client first checks the flag `InterpolateParams` to decide whether or not to use a non-prepared statement. If this flag is `true` and there are at least one arguments then it will 1) interpolate parameters and feed them into the statement, 2) send the [COM_QUERY](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html) to the database with the statement `SELECT * FROM album WHERE id = 322` for example, 3) read the [COM_QUERY response](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query_response.html) to extract the result set and 4) convert the response to an instance of `textRows`. Else, it returns `driver.ErrSkip` to the caller (i.e. `queryDC` in [Figure 6](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21)).

```go
1  func (mc *mysqlConn) query(query string, args []driver.Value) (*textRows, error) {
2    ...
3    if len(args) != 0 {
4      if !mc.cfg.InterpolateParams {
5        return nil, driver.ErrSkip
6      }
7      // try client-side prepare to reduce roundtrip
8      prepared, err := mc.interpolateParams(query, args)
9      if err != nil {
10        return nil, err
11      }
12      query = prepared
13    }
14    // Send command
15    err := mc.writeCommandPacketStr(comQuery, query)
16    if err == nil {
17      // Read result
18      var resLen int
19      resLen, err = mc.readResultSetHeaderPacket()
20      if err == nil {
21        ...
22        // Columns
23        rows.rs.columns, err = mc.readColumns(resLen)
24        return rows, err
25      }
26    }
27    return nil, mc.markBadConn(err)
28  }
```

If `InterpolateParams` is `false`, the control will be back at line 19 in [Figure 6](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), or line 3 in [Figure 6.1](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21). `ctxDriverPrepare` will invoke the method `Prepare` of `*mysqlConn` as in [Figure 2](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), in which the client sends command **[COM_STMT_PREPARE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_prepare.html)** to the server. Next, `rowsiFromStatement` will eventually invokes the method `query` of `*mysqlStmt` as in [Figure 3](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), in which the client sends command **[COM_STMT_EXECUTE](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_execute.html)** to the server.

```go
 1  func (db *DB) queryDC(ctx, txctx context.Context, dc *driverConn, releaseConn func(error), query string, args []any) (*Rows, error) {
 2    ...
 3    withLock(dc, func() {
 4      si, err = ctxDriverPrepare(ctx, dc.ci, query)
 5    })
 6    ...
 7    ds := &driverStmt{Locker: dc, si: si}
 8    rowsi, err := rowsiFromStatement(ctx, dc.ci, ds, args...)
 9    if err != nil {
10      ds.Close()
11      releaseConn(err)
12      return nil, err
13    }
14    ...
15    rows := &Rows{
16      dc:          dc,
17      releaseConn: releaseConn,
18      rowsi:       rowsi,
19      closeStmt:   ds,
20    }
21    rows.initContextClose(ctx, txctx)
22    return rows, nil
23  }
```

Afterward, the control is back at line 13 in [Figure 5](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), where method `Scan` uses the instance of `Rows` returned by `queryDC` to scan an instance of `Album`. At the end of F[igure 5](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), `rows.Close()` is called, which will invoke the method `Close` of `*myStmt` as [Figure 4](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21).

## Implicit Prepared Statement in GORM

In GORM, the logic is the same as implicit prepared statement in standard library because every DML (e.g. `Create`, `Find`, `First`, `Take`, `Update`, `Delete`) eventually invokes `queryDC` in [Figure 6](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21) or `[execDC](https://github.com/golang/go/blob/go1.20/src/database/sql/sql.go#L1658-L1695)`. If there is no prepared statement arguments (i.e. `db.Statement.Vars` is empty), GORM never uses prepared statement. If there is at least one arguments (i.e. `db.Statement.Vars` is not empty), whether prepared statement is used or not depends on whether the configuration `InterpolateParams` is `true` or `false`.

```go
// Create ([source](https://github.com/go-gorm/gorm/blob/master/callbacks/create.go#L97-99))
result, err := db.Statement.ConnPool.ExecContext(
			db.Statement.Context, db.Statement.SQL.String(), db.Statement.Vars...,
		)

// Find, First, Take ([source](https://github.com/go-gorm/gorm/blob/master/callbacks/query.go#L20))
rows, err := db.Statement.ConnPool.QueryContext(
			db.Statement.Context, db.Statement.SQL.String(), db.Statement.Vars...)
		)

// Update ([source](https://github.com/go-gorm/gorm/blob/master/callbacks/update.go#L97))
result, err := db.Statement.ConnPool.ExecContext(
			db.Statement.Context, db.Statement.SQL.String(), db.Statement.Vars...
		)

// Delete ([source](https://github.com/go-gorm/gorm/blob/master/callbacks/delete.go#L159))
result, err := db.Statement.ConnPool.ExecContext(
			db.Statement.Context, db.Statement.SQL.String(), db.Statement.Vars...
		)
```

# Caution regarding Prepared Statement

According to the original [document](http://go-database-sql.org/prepared.html) of `database/sql`:

> At the database level, a prepared statement is bound to a single database connection. The typical flow is that the client sends a SQL statement with placeholders to the server for preparation, the server responds with a statement ID, and then the client executes the statement by sending its ID and parameters.

In Go, however, connections are not exposed directly to the user of the `database/sql` package. You don’t prepare a statement on a connection. You prepare it on a `DB` or a `Tx`. And `database/sql` has some convenience behaviors such as automatic retries. For these reasons, the underlying association between prepared statements and connections, which exists at the driver level, is hidden from your code.

Here’s how it works:
1. When you prepare a statement, it’s prepared on a connection in the pool.
2. The `Stmt` object remembers which connection was used.
3. When you execute the `Stmt`, it tries to use the connection. If it’s not available because it’s closed or busy doing something else, it gets another connection from the pool *and re-prepares the statement with the database on another connection.*

Because statements will be re-prepared as needed when their original connection is busy, it’s possible for high-concurrency usage of the database, which may keep a lot of connections busy, to create a large number of prepared statements. This can result in apparent leaks of statements, statements being prepared and re-prepared more often than you think, and even running into server-side limits on the number of statements.
> 

Due to the fact that prepared statements are re-prepared whenever their original connection is busy, the occurrence of the error in the incident, specifically `Error - 1461: Can't create more than max_prepared_stmt_count statements (current value: ...)` is more likely. Therefore, it is crucial to handle prepared statements with caution and employ appropriate strategies.

# Using Prepared Statement the Right Way

So what is the root cause of the incident and how to use prepared statement properly?

## Close Prepared Statement

Have you noticed anything abnormal in [Figure 0](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21)? The prepared statement is never closed, meaning that it is never deallocated by the database server. *This is the root cause of the incident.*

When we use explicit prepared statement, it is important to invoke both `stmt.Close` to close the prepared statement and invoke `rows.Close` to return the connection to the pool. In [Figure 0](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), because `stmt.Close` is not called, the prepared statement is not closed. This is the place where unfortunate events unfold merely due to neglecting a minor method call. 😄

When we use implicit prepared statement of standard library, we should always call `rows.Close` as line 10 in [Figure 5](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21). `rows.Close` not only returns the connection to the pool but also closes the prepared statement.

When using GORM, there is no requirement to manually close `SELECT` prepared statements since GORM handles this internally (more details can be found [here](https://github.com/go-gorm/gorm/blob/master/callbacks/query.go#L26)). For `CREATE`, `UPDATE`, and `DELETE` statements, GORM eventual invokes the standard library method `[execDC](https://github.com/golang/go/blob/go1.20/src/database/sql/sql.go#L1658-L1695)`, which automatically closes the prepared statement at the [end](https://github.com/golang/go/blob/go1.20/src/database/sql/sql.go#L1693) of this method's execution.

By ensuring that prepared statements are closed after completing their tasks, we can effectively prevent the total number of prepared statements on the server from surpassing the limit set by the system variable [max_prepared_stmt_count](https://dev.mysql.com/doc/refman/5.7/en/server-system-variables.html#sysvar_max_prepared_stmt_count). Thus, it eliminates the likelihood of the error in the incident.

## Set Connection Lifetime

The server maintains caches for prepared statements and stored programs on a per-connection basis. Statements cached for one connection are not accessible to other connections. When a connection ends, the server discards any statements cached for it.

In [Figure 0](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21), neither `MaxConnLifetime` nor `MaxIdleTimeout` is set for any connection in the connection pool `db`, which means the connections never expire. This could result in an unbounded growth in the number of prepared statements if the connections are not closed. 

By setting **not** too long lifetime for a connection, we can reduce the risk that the total number of prepared statements on the server is less likely to surpass the limit set by the system variable [max_prepared_stmt_count](https://dev.mysql.com/doc/refman/5.7/en/server-system-variables.html#sysvar_max_prepared_stmt_count).

## Enable `**InterpolateParams**`

If **`InterpolateParams`** is set to true, placeholders are replaced with interpolated arguments to form a complete statement, and the client will request the server to execute this statement. When `InterpolateParams` is enabled, `db.Query("SELECT * FROM album WHERE title = ?", "L'Amour, Les Baguettes")` will form a complete statement: `SELECT * FROM album WHERE title = 'L\'Amour, Les Baguettes'`. By sending and executing the complete statement on the database server, the number of roundtrips mentioned earlier is significantly reduced, resulting in potential performance improvements. 

To configure `InterpolateParams`, you can add the query parameter `interpolateParams` to the DSN like this: `mysql://user:pass@localhost:3306/dbname?interpolateParams=true`.

Unfortunately, parameter interpolation is not always feasible. According to the original [document](https://github.com/go-sql-driver/mysql#interpolateparams): “It cannot be used together with the multibyte encodings BIG5, CP932, GB2312, GBK or SJIS. These are rejected as they may introduce a SQL injection vulnerability.”

Note that `InterpolateParams` doesn't affect the explicit prepared statement in the standard library. The statement is still prepared and executed by the database server.

## Reuse Prepared Statement

While this point may not directly relate to the incident, it is still an important consideration when aiming to achieve higher performance through the use of prepared statements.

Because prepared statement requires additional round trip, if the network between the client and the server is unstable, this can potentially slow down your application. By default, if you perform the sequence of `Prepare` + `Execute` + `Close` a statement and then repeat the same sequence of `Prepare` + `Execute` + `Close` this statement again, both the client and the server do not retain any memory of the previous statement because it has already been closed. In this case, the database generates a completely new statement for the subsequent `Prepare` + `Query` + `Close` operation.

In terms of efficiency, if a query is executed only once and closed immediately, the prepared statement is worse than a non-prepared statement. The prepared statement is only efficient if it is prepared once, executed many times and is closed at the end. ******maniwood****** has a [blog post](https://www.manniwood.com/2019_04_28/go_pg_stmt.html) that demonstrates the effectiveness and efficiency of reusing prepared statements.

However, we can leverage GORM to reuse prepared statements as much as possible. In GORM, there is a configuration called `[PrepareStmt](https://github.com/go-gorm/gorm/blob/v1.25.2/gorm.go#L35)` that, when enabled, uses a connection pool called `[PreparedStmtDB](https://github.com/go-gorm/gorm/blob/v1.25.2/prepare_stmt.go#L17-L22)` to cache prepared statements. Unlike the default connection pool, which prepares, executes, and closes a statement, the `[PreparedStmtDB](https://github.com/go-gorm/gorm/blob/v1.25.2/prepare_stmt.go#L17-L22)` connection pool takes a different approach. The implementation of `[PreparedStmtDB](https://github.com/go-gorm/gorm/blob/v1.25.2/prepare_stmt.go#L17-L22)` is described in [Figure 9](https://www.notion.so/Prepared-Statement-in-MySQL-and-Go-7a81af3563ee4ad69cfcff80ac65fa49?pvs=21).

`[PreparedStmtDB](https://github.com/go-gorm/gorm/blob/v1.25.2/prepare_stmt.go#L17-L22)` checks application’s local in-memory cache to determine if the statement has already been prepared. If it has, the prepared statement is used for execution. If it has not been prepared yet, `[PreparedStmtDB](https://github.com/go-gorm/gorm/blob/v1.25.2/prepare_stmt.go#L17-L22)` asks server to prepare the statement, saves it to the application’s local in-memory cache, and then requests the server to execute the statement.

When we no longer needs `[PreparedStmtDB](https://github.com/go-gorm/gorm/blob/v1.25.2/prepare_stmt.go#L17-L22)` connection pool, we should close it by `Close` method. This method will eventually ask the server to close every cached prepared statement.

```go
 1  func (db *PreparedStmtDB) prepare(ctx context.Context, conn ConnPool, isTransaction bool, query string) (Stmt, error) {
 2    ...
 3    if stmt, ok := db.Stmts[query]; ok && (!stmt.Transaction || isTransaction) {
 4      ...
 5      return stmt, nil
 6    }
 7    ...
 8    stmt, err := conn.PrepareContext(ctx, query)
 9    if err == nil {
10      db.Stmts[query] = Stmt{Stmt: stmt, Transaction: isTransaction}
11      db.PreparedSQL = append(db.PreparedSQL, query)
12      ...
13    }
14  
15    return db.Stmts[query], err
16  }
17  
18  func (db *PreparedStmtDB) QueryContext(ctx context.Context, query string, args ...interface{}) (rows *sql.Rows, err error) {
19    stmt, err := db.prepare(ctx, db.ConnPool, false, query)
20    if err == nil {
21      rows, err = stmt.QueryContext(ctx, args...)
22      ...
23    }
24    return rows, err
25  }
26  
27  func (db *PreparedStmtDB) ExecContext(ctx context.Context, query string, args ...interface{}) (result sql.Result, err error) {
28    stmt, err := db.prepare(ctx, db.ConnPool, false, query)
29    if err == nil {
30      result, err = stmt.ExecContext(ctx, args...)
31      ...
32    }
33    return result, err
34  }
35  
36  func (db *PreparedStmtDB) Close() {
37    ...
38    for _, query := range db.PreparedSQL {
39      if stmt, ok := db.Stmts[query]; ok {
40        ...
41        go stmt.Close()
42      }
43    }
44  }
```

Unfortunately, there is a problem with the current (v1.25.2) implementation of `PreparedStmtDB`: a prepared statement never evicts from the application’s local in-memory cache except for the case where [an error happens while executing the prepared statement](https://github.com/go-gorm/gorm/blob/v1.25.2/prepare_stmt.go#L141). If the statement is rarely used, this approach could potentially lead to a memory leak. For applications that ue a large number of distinct prepared statements, this approach could result in high memory usage.

# Working with Prepared Statement on Server-side

Apart from using prepared statement properly, we also need monitoring to detect something abnormal with prepared statements.

Firstly, it is highly advisable to thoroughly review the current value assigned to the system variable **`max_prepared_stmt_count`** and ensure that it is appropriately configured to accommodate the anticipated workload.

Next, it is imperative to closely monitor the frequency of prepared statement execution and carefully assess the lifespan of these statements. If a prepared statement is seldom executed but remains active for an extended period, it may indicate a potential leakage.

Moreover, establishing comprehensive monitoring dashboards and implementing alert systems is of utmost importance to track the number of prepared statements within the database. By deploying such monitoring mechanisms, we can proactively detect any abnormal trends or sudden surges in the count of prepared statements, enabling timely interventions.

# Summary

The concept of prepared statements in Database Management Systems (DBMS) is widely known and embraced, as it brings forth a multitude of advantages encompassing security, convenience, and efficiency, which greatly enhance the overall functionality of database operations.

Despite its benefits, prepared statement could cause error if we don’t use it properly.It is crucial to close or deallocate prepared statements from the database server once we have finished working with them, especially when using the Go standard database client library. In GORM, however, there is no need to explicitly close prepared statements because GORM internally handles the management of prepared statements.

In case prepared statement must be avoided but parameterized query is unavoidable, we can use flag `InterpolateParams` ****so that parameters are interpolated and the complete query string is used instead or prepared statement.

# References

- [http://go-database-sql.org/prepared.html](http://go-database-sql.org/prepared.html)
- [https://en.wikipedia.org/wiki/Prepared_statement](https://en.wikipedia.org/wiki/Prepared_statement)
- [https://go.dev/doc/database/prepared-statements](https://go.dev/doc/database/prepared-statements)
- [https://github.com/go-sql-driver/mysql#interpolateparams](https://github.com/go-sql-driver/mysql#interpolateparams)
- [https://www.manniwood.com/2019_04_28/go_pg_stmt.html](https://www.manniwood.com/2019_04_28/go_pg_stmt.html)
- [https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_command_phase_ps.html](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_command_phase_ps.html)
