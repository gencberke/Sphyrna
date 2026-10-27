/* The turn style: a folded tool line opens on a click, as the Agents tab's "Ran N tools" line does. */
document.addEventListener('click', e => {
  const row = e.target.closest('.foldrow');
  if (row) row.parentElement.classList.toggle('open');
});
