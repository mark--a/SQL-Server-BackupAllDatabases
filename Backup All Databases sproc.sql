USE [master]
GO

-- Specify BackupProgress.log as your log file in the job scheduler to handle
-- the output if this is being run as a scheduled task with the SQL Server Agent,
-- as that's the only place you'll be able to get feedback, error/success messages,
-- etc.  If you run as a straight-up T-SQL statement, delete the lines above and
-- including 'AS' (right below these comments) and just execute the command.
CREATE PROCEDURE [dbo].[s_BackupAllDatabases]
AS

DECLARE @Filename nvarchar(255)		-- file name of the backup file
DECLARE @LogFilename nvarchar(255)	-- file name of the log backup file
DECLARE @Timestamp nvarchar(255)	-- complete text timestamp built from system date
DECLARE @SystemTime datetime		-- date that the backup ran
DECLARE @TimeOfDay nvarchar(50)		-- time of day that the backup ran
DECLARE @DayName nvarchar(10)		-- day of the week
DECLARE @name nvarchar(255)			-- database name
DECLARE @Path nvarchar(255)			-- folder location to put backup files on disk (include trailing slash)
DECLARE @BackupRun bit				-- flag to determine if a backup has been run (e.g. skip 'master' for differentials)
DECLARE @MonthString nvarchar(2)	-- holds the two-digit month with leading zero, if necesary

-- @Path is the location on disk.  Could be a UNC share, I believe.
SET @Path = 'C:\Backups\'

-- @DayName is set at the start, since it might actually change over the
-- course of backing up all of the databases.
SET @SystemTime = GETDATE()
SET @DayName = DATENAME(weekday, @SystemTime)

-- A cursor that runs through all of the databases in the system.
-- To exclude specific databases, add to comma separated list in parens "NOT IN ('db1', 'db2')"
DECLARE db_cursor CURSOR FOR
SELECT name FROM master.dbo.sysdatabases WHERE name NOT IN ('tempdb')

-- Open cursor, get first row
OPEN db_cursor
FETCH NEXT FROM db_cursor INTO @name

WHILE @@FETCH_STATUS = 0
	BEGIN
		SET @BackupRun = 0

		-- FULL BACKUP ----------------------------------------------------
		-- Do a FULL backup on @DayName and add the timestamp to the
		-- backup filenames since we want to keep these files indefinitely.
		-- Don't forget to pare them out every now and again to reduce
		-- storage size.  An upgrade to this would be to remove all FULL
		-- backups from the previous month and only keep one of those per
		-- month, e.g.
		IF @DayName = 'FRIDAY'
			BEGIN

				-- reset the @SystemTime to get the current time stamp at the start of each
				-- backup, since they might take a little time (each) to run
				SET @SystemTime = GETDATE()

				-- Get the time of day as a 6-character string HHMMSS, include leading zeroes
				SET @TimeOfDay =  
					SUBSTRING(CONVERT(nvarchar(24), @SystemTime, 113),13,2) +	--hh
					SUBSTRING(CONVERT(nvarchar(24), @SystemTime, 113),16,2) +	--mm
					SUBSTRING(CONVERT(nvarchar(24), @SystemTime, 113),19,2)		--ss

				-- month, w/leading zero
				SET @MonthString = DATEPART(mm, @SystemTime)
				IF (DATEPART(mm, @SystemTime) < 10)
					BEGIN
						SET @MonthString = '0' + @MonthString
					END

				-- Get the date as a 8-character string YYYYMMDD, add the @TimeOfDay to the end, too.
				SET @Timestamp = 
					CONVERT(nvarchar(4), YEAR(@SystemTime)) +							-- YYYY
					@MonthString +														-- MM
					SUBSTRING(CONVERT(nvarchar(24), @SystemTime, 113),1,2) + '_' +		-- DD + '_'
					@TimeOfDay															-- HHMMSS

				SET @Filename = @Path + @Timestamp + '_' + @name + '.bak'
				SET @LogFilename = @Path + @Timestamp + '_' + @name + '_log' + '.bak'

				-- BACKUP DATABASE command, the WITH FORMAT blasts any existing file and creates
				-- a new media (i.e. file on disk).
				BACKUP DATABASE @name TO DISK = @Filename WITH FORMAT

				-- The backup has run, update the flag to see if we'll run the RESTORE VERIFYONLY later
				SET @BackupRun = 1

				-- Backup LOG command, but note that you cannot backup the master db's log.
				-- Likewise, you cannot backup any "SIMPLE" recovery mode databases, so do
				-- an additional test on all of the databases you are backing up.
				IF @name NOT IN ('master')
					BEGIN
						-- Only backup those databases who have their @recovery_model_desc setas 'FULL',
						-- as 'SIMPLE' database recovery models cannot have their LOG backed up.
						IF (SELECT [recovery_model_desc] FROM sys.databases WHERE [name] = @name) = 'FULL'
							BEGIN
								BACKUP LOG @name TO DISK = @LogFilename
							END
					END
			END	-- IF @DayName = ...

		-- DIFFERENTIAL BACKUP ----------------------------------------------------
		-- For each day of the week, backup with '_Monday_Differential_' in the filename.
		-- These will be overwritten each week with the latest and greatest changes to the
		-- database since the last FULL backup.  Can't do a differential backup on 'master'.
		ELSE
			BEGIN
				IF @name NOT IN ('master')
					-- for all databases that are not 'master'
					BEGIN
						SET @Filename = @Path + @DayName + '_Differential_' + @name + '.bak'

						-- Backup command, WITH FORMAT blasts any existing file and creates
						-- a new media (i.e. file on disk).
						BACKUP DATABASE @name TO DISK = @Filename WITH FORMAT, DIFFERENTIAL

						-- The backup has run, update the flag to see if we'll run the RESTORE VERIFYONLY later
						SET @BackupRun = 1
					END
				ELSE
					-- for the 'master' database, do a FULL database backup
					BEGIN
						SET @Filename = @Path + @DayName + '_Full_' + @name + '.bak'

						-- Backup command, WITH FORMAT blasts any existing file and creates
						-- a new media (i.e. file on disk).
						BACKUP DATABASE @name TO DISK = @Filename WITH FORMAT

						-- The backup has run, update the flag to see if we'll run the RESTORE VERIFYONLY later
						SET @BackupRun = 1
					END
			END

		-- VERIFY BACKUP ----------------------------------------------------
		-- Verifies the backup, status is written to STDOUT (in my case, this is the
		-- @Path\BackupProgress.log file that is specified as part of scheduling the
		-- job.  Don't forget to do this scheduling part!
		IF (@BackupRun = 1)
			BEGIN
				RESTORE VERIFYONLY FROM DISK = @Filename
			END

		-- Move on to next database in the list.
		FETCH NEXT FROM db_cursor INTO @name
	END

-- Blast the cursor
CLOSE db_cursor
DEALLOCATE db_cursor




