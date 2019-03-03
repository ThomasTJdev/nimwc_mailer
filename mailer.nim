#
#
#        TTJ
#        (c) Copyright 2018 Thomas Toftgaard Jarløv
#        Plugin for Nim Website Creator: Mailer
#        License: MIT
#
#

import
  asyncdispatch,
  asyncnet,
  datetime2human,
  json,
  logging,
  os,
  parsecfg,
  strutils,

when defined(postgres): import db_postgres
else:                   import db_sqlite

from times import epochTime
import jester
import ../../nimwcpkg/resources/email/email_connection
import ../../nimwcpkg/resources/session/user_data
import ../../nimwcpkg/resources/utils/logging_nimwc
import ../../nimwcpkg/resources/utils/plugins

proc pluginInfo() =
  let (n, v, d, u) = pluginExtractDetails("mailer")
  echo " "
  echo "--------------------------------------------"
  echo "  Package:      " & n
  echo "  Version:      " & v
  echo "  Description:  " & d
  echo "  URL:          " & u
  echo "--------------------------------------------"
  echo " "
pluginInfo()


include "html.tmpl"


proc mailerAddMailevent*(c: var TData, db: DbConn): string =
  ## Add a mail event

  let name        = c.req.params["name"]
  let status      = c.req.params["status"]
  let description = c.req.params["mailtext"]
  let timezone    = parseInt(c.req.params["timezone"].substr(1,2)) * 60 * 60
  let maildate    = if c.req.params["timezone"].substr(0,0) == "-": dateEpoch(c.req.params["maildate"], "YYYY-MM-DD") - timezone else: dateEpoch(c.req.params["maildate"], "YYYY-MM-DD") + timezone

  if maildate == 0:
    return ("Error Mailer plugin: Maildate has a wrong format")

  exec(db, sql"INSERT INTO mailer (name, status, description, author_id, maildate) VALUES (?, ?, ?, ?, ?)", name, status, description, c.userid, maildate)

  return ("OK")



proc mailerUpdateMailevent*(c: var TData, db: DbConn): string =
  ## Update a mail event

  let name        = c.req.params["name"]
  let status      = c.req.params["status"]
  let description = c.req.params["mailtext"]
  let timezone    = parseInt(c.req.params["timezone"].substr(1,2)) * 60 * 60
  let maildate    = if c.req.params["timezone"].substr(0,0) == "-": dateEpoch(c.req.params["maildate"], "YYYY-MM-DD") - timezone else: dateEpoch(c.req.params["maildate"], "YYYY-MM-DD") + timezone

  if maildate == 0 or maildate == 7200:
    return ("Error Mailer plugin: Maildate has a wrong format")

  exec(db, sql"UPDATE mailer SET name = ?, status = ?, description = ?, author_id = ?, maildate = ? WHERE id = ?", name, status, description, c.userid, maildate, c.req.params["mailid"])

  return genMailerViewMail(c, db, c.req.params["mailid"])


proc mailerTestmail*(c: var TData, db: DbConn) =
  ## Send a test mail

  let mail = getRow(db, sql"SELECT mailer.id, mailer.name, mailer.description, person.name FROM mailer LEFT JOIN person ON person.id = mailer.author_id WHERE mailer.id = ?", c.req.params["mailid"])
  let email = getValue(db, sql"SELECT email FROM person WHERE id = ?", c.userid)
  asyncCheck sendMailNow("Reminder: " & mail[1], mail[2], email)



proc mailerDelete*(c: var TData, db: DbConn) =
  ## Delete a mail event

  exec(db, sql"DELETE FROM mailer WHERE id = ?", c.req.params["mailid"])



proc cronMailer(db: DbConn) {.async.} =
  ## Cron mail
  ## Check every nth hour if a mail is scheduled for sending

  info("Mailer plugin: Cron mail is started")
  while true:
    when defined(dev):
      debug("Mailer plugin: Waiting time between cron mails is 5 minute")
      await sleepAsync(60 * 5 * 1000) # 5 minutes

    when not defined(dev):
      await sleepAsync(43200 * 1000) # 12 hours

    let currentTime = toInt(epochTime())
    let currentTime12 = toInt(epochTime() + 43200)

    let allMails = getAllRows(db, sql"SELECT mailer.id, mailer.name, mailer.description, person.name FROM mailer LEFT JOIN person ON person.id = mailer.author_id WHERE maildate > ? AND maildate < ?", currentTime, currentTime12)

    let allRecipients = getAllRows(db, sql"SELECT email FROM person")

    for mail in allMails:
      let mailSubject = "Reminder: " & mail[1]
      var mailMsg     = mail[2]

      for recipient in allRecipients:
        asyncCheck sendMailNow(mailSubject, mailMsg, recipient[0])
        await sleepAsync(1000)




proc mailerStart*(db: DbConn) =
  ## Required proc. Will run on each program start
  ##
  ## If there's no need for this proc, just
  ## discard it. The proc may not be removed.

  info("Mailer plugin: Updating database with Mailer table if not exists")

  if not db.tryExec(sql"""
  create table if not exists mailer(
    id INTEGER primary key,
    author_id INTEGER NOT NULL,
    status INTEGER NOT NULL,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    maildate VARCHAR(100) ,
    modified timestamp not null default (STRFTIME('%s', 'now')),
    creation timestamp not null default (STRFTIME('%s', 'now')),

    foreign key (author_id) references person(id)
  );""", []):
    info("Mailer plugin: Mailer table created in database")

  asyncCheck cronMailer(db)